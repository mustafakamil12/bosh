require_relative '../../spec_helper'

describe 'variable generation with config server', type: :integration do
  with_reset_sandbox_before_each(config_server_enabled: true, user_authentication: 'uaa', uaa_encryption: 'asymmetric')

  def prepend_namespace(key)
    "/#{director_name}/#{deployment_name}/#{key}"
  end

  let(:manifest_hash) do
    Bosh::Spec::Deployments.test_release_manifest.merge(
      {
        'jobs' => [Bosh::Spec::Deployments.job_with_many_templates(
          name: 'our_instance_group',
          templates: [
            {'name' => 'job_1_with_many_properties',
             'properties' => job_properties
            }
          ],
          instances: 1
        )]
      })
  end
  let(:deployment_name) { manifest_hash['name'] }
  let(:director_name) { current_sandbox.director_name }
  let(:cloud_config)  { Bosh::Spec::Deployments.simple_cloud_config }
  let(:config_server_helper) { Bosh::Spec::ConfigServerHelper.new(current_sandbox, logger)}
  let(:client_env) { {'BOSH_CLIENT' => 'test', 'BOSH_CLIENT_SECRET' => 'secret', 'BOSH_CA_CERT' => "#{current_sandbox.certificate_path}"} }
  let(:job_properties) do
    {
      'gargamel' => {
        'color' => 'red'
      },
      'smurfs' => {
        'color' => 'blue'
      }
    }
  end

  before do
    manifest_hash['variables'] = variables
  end

  context 'when variables are defined in manifest' do
    context 'when variables syntax is valid' do
      let (:variables) do
        [
          {
            'name' => 'var_a',
            'type' => 'password'
          },
          {
            'name' => '/var_b',
            'type' => 'password'
          },
          {
            'name' => 'var_c',
            'type' => 'certificate',
            'options' => {
              'common_name' => 'bosh.io',
              'alternative_names' => ['a.bosh.io', 'b.bosh.io']
            }
          }
        ]
      end

      it 'should generate the variables' do
        deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, include_credentials: false, env: client_env)

        var_a = config_server_helper.get_value(prepend_namespace('var_a'))
        var_b = config_server_helper.get_value('/var_b')
        var_c = config_server_helper.get_value(prepend_namespace('var_c'))

        expect(var_a).to_not be_empty
        expect(var_b).to_not be_empty
        expect(var_c).to_not be_empty

        expect(var_c['private_key']).to_not be_empty
        expect(var_c['ca']).to_not be_empty

        certificate_object = OpenSSL::X509::Certificate.new(var_c['certificate'])
        expect(certificate_object.subject.to_s).to include('CN=bosh.io')

        subject_alt_name = certificate_object.extensions.find {|e| e.oid == 'subjectAltName'}
        expect(subject_alt_name.to_s.scan(/a.bosh.io/).count).to eq(1)
        expect(subject_alt_name.to_s.scan(/b.bosh.io/).count).to eq(1)
      end

      context 'when a variable already exists in config server' do
        it 'does NOT re-generate it' do
          config_server_helper.put_value(prepend_namespace('var_a'), 'password_a')

          deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, include_credentials: false, env: client_env)

          var_a = config_server_helper.get_value(prepend_namespace('var_a'))
          expect(var_a).to eq('password_a')
        end
      end

      context 'when a variable type is not known by the config server' do
        before do
          variables << {'name' => 'var_d', 'type' => 'incorrect'}
        end

        it 'throws an error' do
          output, exit_code = deploy_from_scratch(
            no_login: true,
            manifest_hash: manifest_hash,
            cloud_config_hash: cloud_config,
            include_credentials: false,
            env: client_env,
            failure_expected: true,
            return_exit_code: true
          )

          expect(exit_code).to_not eq(0)
          expect(output).to include ("Error: Config Server failed to generate value for '/TestDirector/simple/var_d' with type 'incorrect'. Error: 'Bad Request'")
        end
      end

      context 'when variable is referenced by the manifest' do
        let(:job_properties) do
          {
            'gargamel' => {
              'color' => '((var_a))'
            },
            'smurfs' => {
              'color' => '((/var_b))'
            }
          }
        end

        it 'should use the variable generated value' do
          deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, include_credentials: false, env: client_env)

          var_a = config_server_helper.get_value(prepend_namespace('var_a'))
          var_b = config_server_helper.get_value('/var_b')

          instance = director.instance('our_instance_group', '0', deployment_name: 'simple', include_credentials: false,  env: client_env)

          template_hash = YAML.load(instance.read_job_template('job_1_with_many_properties', 'properties_displayer.yml'))
          expect(template_hash['properties_list']['gargamel_color']).to eq(var_a)
          expect(template_hash['properties_list']['smurfs_color']).to eq(var_b)
        end

        context 'when variable is referenced by a property that have a type in release spec' do
          let(:manifest_hash) do
            Bosh::Spec::Deployments.test_release_manifest.merge(
              {
                'jobs' => [Bosh::Spec::Deployments.job_with_many_templates(
                  name: 'our_instance_group',
                  templates: [
                    {'name' => 'job_with_property_types',
                     'properties' => job_properties
                    }
                  ],
                  instances: 3
                )]
              })
          end

          let (:variables) do
            [
              {
                'name' => 'var_a',
                'type' => 'password'
              },
              {
                'name' => '/var_b',
                'type' => 'password'
              },
              {
                'name' => 'var_c',
                'type' => 'certificate',
                'options' => {
                  'common_name' => 'smurfs.io',
                  'alternative_names' => ['a.smurfs.io', 'b.smurfs.io']
                }
              }
            ]
          end

          let(:job_properties) do
            {
              'smurfs' => {
                'phone_password' => '((var_a))',
                'happiness_level' => 5
              },
              'gargamel' => {
                'secret_recipe' => '((var_c))',
                'password' => 'something',
                'hard_coded_cert' => '((/var_b))',
                'cert' => '((var_c))'
              }
            }
          end

          it 'uses the type defined by the variable' do
            deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, include_credentials: false, env: client_env)
            instance = director.instance('our_instance_group', '0', deployment_name: 'simple', include_credentials: false,  env: client_env)

            properties_displayer_template = instance.read_job_template('job_with_property_types', 'properties_displayer.yml')
            expect(properties_displayer_template).to include('gargamel_secret_recipe: {')
            expect(properties_displayer_template).to include('BEGIN CERTIFICATE')

            var_b = config_server_helper.get_value('/var_b')
            hardcoded_cert = instance.read_job_template('job_with_property_types', 'hardcoded_cert.pem')
            expect(hardcoded_cert).to eq(var_b)
            expect(hardcoded_cert).to_not include('BEGIN CERTIFICATE')

            var_c = config_server_helper.get_value(prepend_namespace('var_c'))
            expect(var_c['private_key']).to_not be_empty
            expect(var_c['ca']).to_not be_empty

            certificate_object = OpenSSL::X509::Certificate.new(var_c['certificate'])
            expect(certificate_object.subject.to_s).to include('CN=smurfs.io')

            subject_alt_name = certificate_object.extensions.find {|e| e.oid == 'subjectAltName'}
            expect(subject_alt_name.to_s.scan(/a.smurfs.io/).count).to eq(1)
            expect(subject_alt_name.to_s.scan(/b.smurfs.io/).count).to eq(1)
          end

          context 'when the variable is referenced as a mid-string interpolation' do
            let (:variables) do
              [
                {
                  'name' => '/var_a',
                  'type' => 'password'
                },
                {
                  'name' => 'var_b',
                  'type' => 'certificate',
                  'options' => {
                    'common_name' => 'smurfs.io',
                    'alternative_names' => ['a.smurfs.io', 'b.smurfs.io']
                  }
                }
              ]
            end

            let(:job_properties) do
              {
                'smurfs' => {
                  'phone_password' => 'very secret',
                  'happiness_level' => 'my happy level is secret: ((/var_a))'
                },
                'gargamel' => {
                  'secret_recipe' => '((var_b))',
                  'password' => 'something',
                  'hard_coded_cert' => 'meow',
                  'cert' => '((var_b))'
                }
              }
            end

            it 'generates that variable as normal, using the type provided in the variable section' do
              deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, include_credentials: false, env: client_env)
              instance = director.instance('our_instance_group', '0', deployment_name: 'simple', include_credentials: false,  env: client_env)

              generated_var_a = config_server_helper.get_value('/var_a')

              properties_displayer_template = instance.read_job_template('job_with_property_types', 'properties_displayer.yml')
              expect(properties_displayer_template).to include("my happy level is secret: #{generated_var_a}")
            end
          end
        end
      end
    end

    context 'when variables section syntax are NOT valid' do
      let (:variables) do
        ['hello', 'bye']
      end

      # TODO: Currently the go cli validates the variables section in the manifest, even if it is not generating the values
      xit 'should throw an error' do
        output, exit_code = deploy_from_scratch(
          no_login: true,
          manifest_hash: manifest_hash,
          cloud_config_hash: cloud_config,
          include_credentials: false,
          env: client_env,
          failure_expected: true,
          return_exit_code: true
        )

        expect(exit_code).to_not eq(0)
        expect(output).to include ("Error: Config Server failed to generate value for '/TestDirector/simple/var_d' with type 'incorrect'. Error: 'Bad Request'")
      end
    end
  end
end
