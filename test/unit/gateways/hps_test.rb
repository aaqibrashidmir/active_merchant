require 'test_helper'

class HpsTest < Test::Unit::TestCase
  include CommStub

  def setup
    @gateway = HpsGateway.new({ secret_api_key: '12' })

    @credit_card = credit_card
    @amount = 100
    @check = check(account_number: '1357902468', routing_number: '122000030', number: '1234', account_type: 'SAVINGS')
    @check_amount = 2000

    @options = {
      order_id: '1',
      billing_address: address,
      description: 'Store Purchase'
    }
  end

  def test_api_version
    assert_equal '1.0', @gateway.fetch_version
  end

  def test_api_version_in_xml
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:Ver1.0>/, data)
    end.respond_with(successful_charge_response)

    assert_success response
  end

  def test_successful_purchase
    @gateway.expects(:ssl_post).returns(successful_charge_response)

    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_instance_of Response, response
    assert_success response
  end

  def test_successful_purchase_no_address
    @gateway.expects(:ssl_post).returns(successful_charge_response)

    options = {
      order_id: '1',
      description: 'Store Purchase'
    }
    response = @gateway.purchase(@amount, @credit_card, options)
    assert_instance_of Response, response
    assert_success response
  end

  def test_successful_zip_formatting
    @options[:billing_address][:zip] = '12345-1234 '

    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:CardHolderZip>123451234<\/hps:CardHolderZip>/, data)
    end.respond_with(successful_swipe_purchase_response)

    assert_success response
  end

  def test_successful_check_purchase
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@check_amount, @check, @options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:CheckSale><hps:Block1><hps:CheckAction>SALE<\/hps:CheckAction>/, data)
    end.respond_with(successful_check_purchase_response)

    assert_success response
  end

  def test_check_purchase_does_not_raise_no_method_error_when_account_type_missing
    check = @check.dup
    check.account_type = nil
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@check_amount, check, @options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:CheckSale><hps:Block1><hps:CheckAction>SALE<\/hps:CheckAction>/, data)
    end.respond_with(successful_check_purchase_response)

    assert_success response
  end

  def test_check_purchase_does_not_raise_no_method_error_when_account_holder_type_missing
    check = @check.dup
    check.account_holder_type = nil
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@check_amount, check, @options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:CheckSale><hps:Block1><hps:CheckAction>SALE<\/hps:CheckAction>/, data)
    end.respond_with(successful_check_purchase_response)

    assert_success response
  end

  def test_failed_purchase
    @gateway.expects(:ssl_post).returns(failed_charge_response)

    response = @gateway.purchase(10.34, @credit_card, @options)
    assert_instance_of Response, response
    assert_failure response
  end

  def test_successful_authorize
    @gateway.expects(:ssl_post).returns(successful_authorize_response)

    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_instance_of Response, response
    assert_success response
  end

  def test_successful_authorize_no_address
    @gateway.expects(:ssl_post).returns(successful_charge_response)

    options = {
      order_id: '1',
      description: 'Store Authorize'
    }
    response = @gateway.authorize(@amount, @credit_card, options)
    assert_instance_of Response, response
    assert_success response
  end

  def test_failed_authorize
    @gateway.expects(:ssl_post).returns(failed_authorize_response)

    response = @gateway.authorize(10.34, @credit_card, @options)
    assert_instance_of Response, response
    assert_failure response
  end

  def test_successful_capture
    @gateway.expects(:ssl_post).returns(successful_capture_response)

    capture_response = @gateway.capture(@amount, 16072899)
    assert_instance_of Response, capture_response
    assert_success capture_response
  end

  def test_failed_capture
    @gateway.expects(:ssl_post).returns(failed_capture_response)

    capture_response = @gateway.capture(@amount, 216072899)
    assert_instance_of Response, capture_response
    assert_failure capture_response
    assert_equal 'Transaction rejected because the referenced original transaction is invalid. Subject \'216072899\'.  Original transaction not found.', capture_response.message
  end

  def test_successful_refund
    @gateway.expects(:ssl_post).returns(successful_refund_response)

    refund = @gateway.refund(@amount, 'transaction_id')
    assert_instance_of Response, refund
    assert_success refund
    assert_equal '0', refund.params['GatewayRspCode']
  end

  def test_failed_refund
    @gateway.expects(:ssl_post).returns(failed_refund_response)

    refund = @gateway.refund(@amount, '169054')
    assert_instance_of Response, refund
    assert_failure refund
  end

  def test_successful_credit
    @gateway.expects(:ssl_post).returns(successful_refund_response)

    credit = @gateway.credit(@amount, @credit_card)
    assert_success credit
  end

  def test_failed_credit
    @gateway.expects(:ssl_post).returns(failed_refund_response)

    credit = @gateway.refund(@amount, @credit_card)
    assert_failure credit
  end

  def test_successful_void
    @gateway.expects(:ssl_post).returns(successful_void_response)

    void = @gateway.void('169054')
    assert_instance_of Response, void
    assert_success void
  end

  def test_successful_check_void
    void = stub_comms(@gateway, :ssl_request) do
      @gateway.void('169054', check_void: true)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:Transaction><hps:CheckVoid>/, data)
    end.respond_with(successful_check_void_response)

    assert_success void
  end

  def test_failed_void
    @gateway.expects(:ssl_post).returns(failed_refund_response)

    void = @gateway.void('169054')
    assert_instance_of Response, void
    assert_failure void
  end

  def test_successful_recurring_purchase
    stored_credential_params = {
      reason_type: 'recurring'
    }

    @gateway.expects(:ssl_post).returns(successful_charge_response)

    response = @gateway.purchase(@amount, @credit_card, @options.merge({ stored_credential: stored_credential_params }))
    assert_instance_of Response, response
    assert_success response
  end

  def test_successful_purchase_with_swipe_no_encryption
    @gateway.expects(:ssl_post).returns(successful_swipe_purchase_response)

    @credit_card.track_data = '%B547888879888877776?;5473500000000014=25121019999888877776?'
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_purchase_with_swipe_bad_track_data
    @gateway.expects(:ssl_post).returns(failed_swipe_purchase_response)

    @credit_card.track_data = '%B547888879888877776?;?'
    response = @gateway.purchase(@amount, @credit_card, @options)

    assert_failure response
    assert_equal 'Transaction was rejected because the track data could not be read.', response.message
  end

  def test_successful_purchase_with_swipe_encryption_type_01
    @gateway.expects(:ssl_post).returns(successful_swipe_purchase_response)

    @options[:encryption_type] = '01'
    @credit_card.track_data = '&lt;E1052711%B5473501000000014^MC TEST CARD^251200000000000000000000000000000000?|GVEY/MKaKXuqqjKRRueIdCHPPoj1gMccgNOtHC41ymz7bIvyJJVdD3LW8BbwvwoenI+|+++++++C4cI2zjMp|11;5473501000000014=25120000000000000000?|8XqYkQGMdGeiIsgM0pzdCbEGUDP|+++++++C4cI2zjMp|00|||/wECAQECAoFGAgEH2wYcShV78RZwb3NAc2VjdXJlZXhjaGFuZ2UubmV0PX50qfj4dt0lu9oFBESQQNkpoxEVpCW3ZKmoIV3T93zphPS3XKP4+DiVlM8VIOOmAuRrpzxNi0TN/DWXWSjUC8m/PI2dACGdl/hVJ/imfqIs68wYDnp8j0ZfgvM26MlnDbTVRrSx68Nzj2QAgpBCHcaBb/FZm9T7pfMr2Mlh2YcAt6gGG1i2bJgiEJn8IiSDX5M2ybzqRT86PCbKle/XCTwFFe1X|&gt;'
    response = @gateway.purchase(@amount, @credit_card, @options)

    assert_success response
    assert_equal 'Success', response.message
  end

  def test_successful_purchase_with_swipe_encryption_type_02
    @gateway.expects(:ssl_post).returns(successful_swipe_purchase_response)

    @options[:encryption_type] = '02'
    @options[:encrypted_track_number] = 2
    @options[:ktb] = '/wECAQECAoFGAgEH3QgVTDT6jRZwb3NAc2VjdXJlZXhjaGFuZ2UubmV0Nkt08KRSPigRYcr1HVgjRFEvtUBy+VcCKlOGA3871r3SOkqDvH2+30insdLHmhTLCc4sC2IhlobvWnutAfylKk2GLspH/pfEnVKPvBv0hBnF4413+QIRlAuGX6+qZjna2aMl0kIsjEY4N6qoVq2j5/e5I+41+a2pbm61blv2PEMAmyuCcAbN3/At/1kRZNwN6LSUg9VmJO83kOglWBe1CbdFtncq'
    @credit_card.track_data = '7SV2BK6ESQPrq01iig27E74SxMg'
    response = @gateway.purchase(@amount, @credit_card, @options)

    assert_success response
    assert_equal 'Success', response.message
  end

  def test_successful_verify
    @gateway.expects(:ssl_post).returns(successful_verify_response)

    response = @gateway.verify(@credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_verify
    @gateway.expects(:ssl_post).returns(failed_verify_response)
    @credit_card.number = 12345

    response = @gateway.verify(@credit_card, @options)

    assert_failure response
    assert_equal 'The card number is not a valid credit card number.', response.message
  end

  def test_test_returns_true
    gateway = HpsGateway.new(fixtures(:hps))
    assert_equal true, gateway.send(:test?)
  end

  def test_test_returns_false
    assert_false @gateway.send(:test?)
  end

  def test_transcript_scrubbing
    assert @gateway.supports_scrubbing?
    assert_equal @gateway.scrub(pre_scrub), post_scrub
  end

  def test_account_number_scrubbing
    assert_equal @gateway.scrub(pre_scrubbed_account_number), post_scrubbed_account_number
  end

  def test_successful_purchase_with_apple_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(successful_charge_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :apple_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_purchase_with_apple_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(failed_charge_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :apple_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_purchase_with_apple_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(successful_charge_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :apple_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_purchase_with_apple_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(failed_charge_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :apple_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_auth_with_apple_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(successful_authorize_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :apple_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_auth_with_apple_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(failed_authorize_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :apple_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_auth_with_apple_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(successful_authorize_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :apple_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_auth_with_apple_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(failed_authorize_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :apple_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_purchase_with_android_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(successful_charge_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :android_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_purchase_with_android_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(failed_charge_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :android_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_purchase_with_android_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(successful_charge_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :android_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_purchase_with_android_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(failed_charge_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :android_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_auth_with_android_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(successful_authorize_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :android_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_auth_with_android_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(failed_authorize_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :android_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_auth_with_android_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(successful_authorize_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :android_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_auth_with_android_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(failed_authorize_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :android_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_purchase_with_google_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(successful_charge_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :google_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_purchase_with_google_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(failed_charge_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :google_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_purchase_with_google_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(successful_charge_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :google_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_purchase_with_google_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(failed_charge_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :google_pay
    )
    assert response = @gateway.purchase(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_auth_with_google_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(successful_authorize_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :google_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_auth_with_google_pay_raw_cryptogram_with_eci
    @gateway.expects(:ssl_post).returns(failed_authorize_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      eci: '05',
      source: :google_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_successful_auth_with_google_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(successful_authorize_response)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :google_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_success response
    assert_equal 'Success', response.message
  end

  def test_failed_auth_with_google_pay_raw_cryptogram_without_eci
    @gateway.expects(:ssl_post).returns(failed_authorize_response_decline)

    credit_card = network_tokenization_credit_card(
      '4242424242424242',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      verification_value: nil,
      source: :google_pay
    )
    assert response = @gateway.authorize(@amount, credit_card, @options)
    assert_failure response
    assert_equal 'The card was declined.', response.message
  end

  def test_three_d_secure_visa
    @credit_card.number = '4012002000060016'
    @credit_card.brand = 'visa'

    options = {
      three_d_secure: {
        version: '2.2.0',
        cavv: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
        eci: '05',
        ds_transaction_id: 'TTBCSkVTa1ZpbDI1bjRxbGk5ODE='
      }
    }

    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:Secure3D>(.*)<\/hps:Secure3D>/, data)
      assert_match(/<hps:Version>#{options[:three_d_secure][:version]}<\/hps:Version>/, data)
      assert_match(/<hps:AuthenticationValue>#{options[:three_d_secure][:cavv]}<\/hps:AuthenticationValue>/, data)
      assert_match(/<hps:ECI>5<\/hps:ECI>/, data)
      assert_match(/<hps:DirectoryServerTxnId>#{options[:three_d_secure][:ds_transaction_id]}<\/hps:DirectoryServerTxnId>/, data)
    end.respond_with(successful_charge_response)

    assert_success response
    assert_equal 'Success', response.message
  end

  def test_three_d_secure_mastercard
    @credit_card.number = '5473500000000014'
    @credit_card.brand = 'master'

    options = {
      three_d_secure: {
        version: '2.2.0',
        cavv: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
        eci: '05',
        ds_transaction_id: 'TTBCSkVTa1ZpbDI1bjRxbGk5ODE='
      }
    }

    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:Secure3D>(.*)<\/hps:Secure3D>/, data)
      assert_match(/<hps:Version>#{options[:three_d_secure][:version]}<\/hps:Version>/, data)
      assert_match(/<hps:AuthenticationValue>#{options[:three_d_secure][:cavv]}<\/hps:AuthenticationValue>/, data)
      assert_match(/<hps:ECI>5<\/hps:ECI>/, data)
      assert_match(/<hps:DirectoryServerTxnId>#{options[:three_d_secure][:ds_transaction_id]}<\/hps:DirectoryServerTxnId>/, data)
    end.respond_with(successful_charge_response)

    assert_success response
    assert_equal 'Success', response.message
  end

  def test_three_d_secure_discover
    @credit_card.number = '6011000990156527'
    @credit_card.brand = 'discover'

    options = {
      three_d_secure: {
        cavv: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
        eci: '5',
        ds_transaction_id: 'TTBCSkVTa1ZpbDI1bjRxbGk5ODE='
      }
    }

    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:Secure3D>(.*)<\/hps:Secure3D>/, data)
      assert_match(/<hps:AuthenticationValue>#{options[:three_d_secure][:cavv]}<\/hps:AuthenticationValue>/, data)
      assert_match(/<hps:ECI>5<\/hps:ECI>/, data)
      assert_match(/<hps:DirectoryServerTxnId>#{options[:three_d_secure][:ds_transaction_id]}<\/hps:DirectoryServerTxnId>/, data)
    end.respond_with(successful_charge_response)

    assert_success response
    assert_equal 'Success', response.message
  end

  def test_three_d_secure_amex
    @credit_card.number = '372700699251018'
    @credit_card.brand = 'american_express'

    options = {
      three_d_secure: {
        cavv: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
        eci: '05',
        ds_transaction_id: 'TTBCSkVTa1ZpbDI1bjRxbGk5ODE='
      }
    }

    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:Secure3D>(.*)<\/hps:Secure3D>/, data)
      assert_match(/<hps:AuthenticationValue>#{options[:three_d_secure][:cavv]}<\/hps:AuthenticationValue>/, data)
      assert_match(/<hps:ECI>5<\/hps:ECI>/, data)
      assert_match(/<hps:DirectoryServerTxnId>#{options[:three_d_secure][:ds_transaction_id]}<\/hps:DirectoryServerTxnId>/, data)
    end.respond_with(successful_charge_response)

    assert_success response
    assert_equal 'Success', response.message
  end

  def test_three_d_secure_jcb
    @credit_card.number = '372700699251018'
    @credit_card.brand = 'jcb'

    options = {
      three_d_secure: {
        cavv: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
        eci: '5',
        xid: 'TTBCSkVTa1ZpbDI1bjRxbGk5ODE='
      }
    }

    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, options)
    end.check_request do |_method, _endpoint, data, _headers|
      refute_match(/<hps:SecureECommerce>(.*)<\/hps:SecureECommerce>/, data)
      refute_match(/<hps:PaymentDataSource>(.*)<\/hps:PaymentDataSource>/, data)
      refute_match(/<hps:TypeOfPaymentData>3DSecure<\/hps:TypeOfPaymentData>/, data)
      refute_match(/<hps:PaymentData>#{options[:three_d_secure][:cavv]}<\/hps:PaymentData>/, data)
      refute_match(/<hps:ECommerceIndicator>5<\/hps:ECommerceIndicator>/, data)
      refute_match(/<hps:XID>#{options[:three_d_secure][:xid]}<\/hps:XID>/, data)
    end.respond_with(successful_charge_response)

    assert_success response
    assert_equal 'Success', response.message
  end

  def test_successful_auth_with_stored_credentials
    stored_credential_params = {
      initial_transaction: false,
      reason_type: 'recurring',
      initiator: 'customer',
      network_transaction_id: 12345
    }

    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@amount, @credit_card, @options.merge({ stored_credential: stored_credential_params }))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:CardOnFile>C<\/hps:CardOnFile>/, data)
      assert_match(/<hps:CardBrandTxnId>12345<\/hps:CardBrandTxnId>/, data)
      assert_match(/<hps:OneTime>N<\/hps:OneTime>/, data)
    end.respond_with(successful_charge_response)

    assert_success response
    assert_equal 'Success', response.message
  end

  def test_truncates_long_invoicenbr
    response = stub_comms(@gateway, :ssl_request) do
      @gateway.purchase(@check_amount, @check, @options.merge(order_id: '04863692e6b56aaed85760b3d0879afd18b980da0521f6454c007a838435e561'))
    end.check_request do |_method, _endpoint, data, _headers|
      assert_match(/<hps:InvoiceNbr>04863692e6b56aaed85760b3d0879afd18b980da0521f6454c007a838435<\/hps:InvoiceNbr>/, data)
    end.respond_with(successful_check_purchase_response)

    assert_success response
    assert_equal 'Success', response.message
  end

  private

  def successful_charge_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
           <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
              <Ver1.0>
                 <Header>
                    <LicenseId>95878</LicenseId>
                    <SiteId>95881</SiteId>
                    <DeviceId>2409000</DeviceId>
                    <GatewayTxnId>15927453</GatewayTxnId>
                    <GatewayRspCode>0</GatewayRspCode>
                    <GatewayRspMsg>Success</GatewayRspMsg>
                    <RspDT>2014-03-14T15:40:25.4686202</RspDT>
                 </Header>
                 <Transaction>
                    <CreditSale>
                       <RspCode>00</RspCode>
                       <RspText>APPROVAL</RspText>
                       <AuthCode>36987A</AuthCode>
                       <AVSRsltCode>0</AVSRsltCode>
                       <CVVRsltCode>M</CVVRsltCode>
                       <RefNbr>407313649105</RefNbr>
                       <AVSResultCodeAction>ACCEPT</AVSResultCodeAction>
                       <CVVResultCodeAction>ACCEPT</CVVResultCodeAction>
                       <CardType>Visa</CardType>
                       <AVSRsltText>AVS Not Requested.</AVSRsltText>
                       <CVVRsltText>Match.</CVVRsltText>
                    </CreditSale>
                 </Transaction>
              </Ver1.0>
           </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def successful_check_purchase_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
          <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
            <Ver1.0>
              <Header>
                <LicenseId>144379</LicenseId>
                <SiteId>144474</SiteId>
                <DeviceId>6407594</DeviceId>
                <GatewayTxnId>1284694345</GatewayTxnId>
                <GatewayRspCode>0</GatewayRspCode>
                <GatewayRspMsg>Success</GatewayRspMsg>
                <RspDT>2020-01-13T15:11:24.735047</RspDT>
              </Header>
              <Transaction>
                <CheckSale>
                  <RspCode>0</RspCode>
                  <RspMessage>Transaction Approved. BatchID:31796</RspMessage>
                </CheckSale>
              </Transaction>
            </Ver1.0>
          </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def failed_charge_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
           <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
              <Ver1.0>
                 <Header>
                    <LicenseId>21229</LicenseId>
                    <SiteId>21232</SiteId>
                    <DeviceId>1525997</DeviceId>
                    <GatewayTxnId>16099851</GatewayTxnId>
                    <GatewayRspCode>0</GatewayRspCode>
                    <GatewayRspMsg>Success</GatewayRspMsg>
                    <RspDT>2014-03-17T13:01:55.851307</RspDT>
                 </Header>
                 <Transaction>
                    <CreditSale>
                       <RspCode>02</RspCode>
                       <RspText>CALL</RspText>
                       <AuthCode />
                       <AVSRsltCode>0</AVSRsltCode>
                       <RefNbr>407613674802</RefNbr>
                       <CardType>Visa</CardType>
                       <AVSRsltText>AVS Not Requested.</AVSRsltText>
                    </CreditSale>
                 </Transaction>
              </Ver1.0>
           </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def failed_charge_response_decline
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
           <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
              <Ver1.0>
                 <Header>
                    <LicenseId>21229</LicenseId>
                    <SiteId>21232</SiteId>
                    <DeviceId>1525997</DeviceId>
                    <GatewayTxnId>16099851</GatewayTxnId>
                    <GatewayRspCode>0</GatewayRspCode>
                    <GatewayRspMsg>Success</GatewayRspMsg>
                    <RspDT>2014-03-17T13:01:55.851307</RspDT>
                 </Header>
                 <Transaction>
                    <CreditSale>
                       <RspCode>05</RspCode>
                       <RspText>DECLINE</RspText>
                       <AuthCode />
                       <AVSRsltCode>0</AVSRsltCode>
                       <RefNbr>407613674802</RefNbr>
                       <CardType>Visa</CardType>
                       <AVSRsltText>AVS Not Requested.</AVSRsltText>
                    </CreditSale>
                 </Transaction>
              </Ver1.0>
           </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def successful_authorize_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
           <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
              <Ver1.0>
                 <Header>
                    <LicenseId>21229</LicenseId>
                    <SiteId>21232</SiteId>
                    <DeviceId>1525997</DeviceId>
                    <GatewayTxnId>16072891</GatewayTxnId>
                    <GatewayRspCode>0</GatewayRspCode>
                    <GatewayRspMsg>Success</GatewayRspMsg>
                    <RspDT>2014-03-17T13:05:34.5819712</RspDT>
                 </Header>
                 <Transaction>
                    <CreditAuth>
                       <RspCode>00</RspCode>
                       <RspText>APPROVAL</RspText>
                       <AuthCode>43204A</AuthCode>
                       <AVSRsltCode>0</AVSRsltCode>
                       <CVVRsltCode>M</CVVRsltCode>
                       <RefNbr>407613674895</RefNbr>
                       <AVSResultCodeAction>ACCEPT</AVSResultCodeAction>
                       <CVVResultCodeAction>ACCEPT</CVVResultCodeAction>
                       <CardType>Visa</CardType>
                       <AVSRsltText>AVS Not Requested.</AVSRsltText>
                       <CVVRsltText>Match.</CVVRsltText>
                    </CreditAuth>
                 </Transaction>
              </Ver1.0>
           </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def failed_authorize_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
          <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
             <Ver1.0>
                <Header>
                   <LicenseId>21229</LicenseId>
                   <SiteId>21232</SiteId>
                   <DeviceId>1525997</DeviceId>
                   <GatewayTxnId>16088893</GatewayTxnId>
                   <GatewayRspCode>0</GatewayRspCode>
                   <GatewayRspMsg>Success</GatewayRspMsg>
                   <RspDT>2014-03-17T13:06:45.449707</RspDT>
                </Header>
                <Transaction>
                   <CreditAuth>
                      <RspCode>54</RspCode>
                      <RspText>EXPIRED CARD</RspText>
                      <AuthCode />
                      <AVSRsltCode>0</AVSRsltCode>
                      <RefNbr>407613674811</RefNbr>
                      <CardType>Visa</CardType>
                      <AVSRsltText>AVS Not Requested.</AVSRsltText>
                   </CreditAuth>
                </Transaction>
             </Ver1.0>
          </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def failed_authorize_response_decline
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
          <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
             <Ver1.0>
                <Header>
                   <LicenseId>21229</LicenseId>
                   <SiteId>21232</SiteId>
                   <DeviceId>1525997</DeviceId>
                   <GatewayTxnId>16088893</GatewayTxnId>
                   <GatewayRspCode>0</GatewayRspCode>
                   <GatewayRspMsg>Success</GatewayRspMsg>
                   <RspDT>2014-03-17T13:06:45.449707</RspDT>
                </Header>
                <Transaction>
                   <CreditAuth>
                      <RspCode>05</RspCode>
                      <RspText>DECLINE</RspText>
                      <AuthCode />
                      <AVSRsltCode>0</AVSRsltCode>
                      <RefNbr>407613674811</RefNbr>
                      <CardType>Visa</CardType>
                      <AVSRsltText>AVS Not Requested.</AVSRsltText>
                   </CreditAuth>
                </Transaction>
             </Ver1.0>
          </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def successful_capture_response
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
        <soap:Body>
          <PosResponse rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway" xmlns="http://Hps.Exchange.PosGateway">
            <Ver1.0>
              <Header>
                <LicenseId>21229</LicenseId>
                <SiteId>21232</SiteId>
                <DeviceId>1525997</DeviceId>
                <GatewayTxnId>17213037</GatewayTxnId>
                <GatewayRspCode>0</GatewayRspCode>
                <GatewayRspMsg>Success</GatewayRspMsg>
                <RspDT>2014-05-16T14:45:48.9906929</RspDT>
              </Header>
              <Transaction>
                <CreditAddToBatch />
              </Transaction>
            </Ver1.0>
          </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def failed_capture_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
           <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
              <Ver1.0>
                 <Header>
                    <LicenseId>21229</LicenseId>
                    <SiteId>21232</SiteId>
                    <DeviceId>1525997</DeviceId>
                    <GatewayTxnId>16104055</GatewayTxnId>
                    <GatewayRspCode>3</GatewayRspCode>
                    <GatewayRspMsg>Transaction rejected because the referenced original transaction is invalid. Subject '216072899'.  Original transaction not found.</GatewayRspMsg>
                    <RspDT>2014-03-17T14:20:32.355307</RspDT>
                 </Header>
              </Ver1.0>
           </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def successful_refund_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
           <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
              <Ver1.0>
                 <Header>
                    <LicenseId>21229</LicenseId>
                    <SiteId>21232</SiteId>
                    <DeviceId>1525997</DeviceId>
                    <SiteTrace />
                    <GatewayTxnId>16092738</GatewayTxnId>
                    <GatewayRspCode>0</GatewayRspCode>
                    <GatewayRspMsg>Success</GatewayRspMsg>
                    <RspDT>2014-03-17T13:31:42.0231712</RspDT>
                 </Header>
                 <Transaction>
                    <CreditReturn />
                 </Transaction>
              </Ver1.0>
           </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def failed_refund_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
           <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
              <Ver1.0>
                 <Header>
                    <LicenseId>21229</LicenseId>
                    <SiteId>21232</SiteId>
                    <DeviceId>1525997</DeviceId>
                    <SiteTrace />
                    <GatewayTxnId>16092766</GatewayTxnId>
                    <GatewayRspCode>3</GatewayRspCode>
                    <GatewayRspMsg>Transaction rejected because the referenced original transaction is invalid.</GatewayRspMsg>
                    <RspDT>2014-03-17T13:48:55.3203712</RspDT>
                 </Header>
              </Ver1.0>
           </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def successful_void_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
           <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
              <Ver1.0>
                 <Header>
                    <LicenseId>21229</LicenseId>
                    <SiteId>21232</SiteId>
                    <DeviceId>1525997</DeviceId>
                    <GatewayTxnId>16092767</GatewayTxnId>
                    <GatewayRspCode>0</GatewayRspCode>
                    <GatewayRspMsg>Success</GatewayRspMsg>
                    <RspDT>2014-03-17T13:53:43.6863712</RspDT>
                 </Header>
                 <Transaction>
                    <CreditVoid />
                 </Transaction>
              </Ver1.0>
           </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def successful_check_void_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
          <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
            <Ver1.0>
              <Header>
                <LicenseId>144379</LicenseId>
                <SiteId>144474</SiteId>
                <DeviceId>6407594</DeviceId>
                <GatewayTxnId>1284696436</GatewayTxnId>
                <GatewayRspCode>0</GatewayRspCode>
                <GatewayRspMsg>Success</GatewayRspMsg>
                <RspDT>2020-01-13T15:44:24.3568038</RspDT>
              </Header>
              <Transaction>
                <CheckVoid>
                  <RspCode>0</RspCode>
                  <RspMessage>Transaction Approved.</RspMessage>
                </CheckVoid>
              </Transaction>
            </Ver1.0>
          </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def failed_void_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
           <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
              <Ver1.0>
                 <Header>
                    <LicenseId>21229</LicenseId>
                    <SiteId>21232</SiteId>
                    <DeviceId>1525997</DeviceId>
                    <GatewayTxnId>16103858</GatewayTxnId>
                    <GatewayRspCode>3</GatewayRspCode>
                    <GatewayRspMsg>Transaction rejected because the referenced original transaction is invalid. Subject '169054'.  Original transaction not found.</GatewayRspMsg>
                    <RspDT>2014-03-17T13:55:56.8947712</RspDT>
                 </Header>
              </Ver1.0>
           </PosResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  def successful_swipe_purchase_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
         <soap:Body>
            <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
               <Ver1.0>
                  <Header>
                     <LicenseId>95878</LicenseId>
                     <SiteId>95881</SiteId>
                     <DeviceId>2409000</DeviceId>
                     <GatewayTxnId>17596558</GatewayTxnId>
                     <GatewayRspCode>0</GatewayRspCode>
                     <GatewayRspMsg>Success</GatewayRspMsg>
                     <RspDT>2014-05-26T10:27:30.4211513</RspDT>
                  </Header>
                  <Transaction>
                     <CreditSale>
                        <RspCode>00</RspCode>
                        <RspText>APPROVAL</RspText>
                        <AuthCode>037677</AuthCode>
                        <AVSRsltCode>0</AVSRsltCode>
                        <RefNbr>414614470800</RefNbr>
                        <AVSResultCodeAction>ACCEPT</AVSResultCodeAction>
                        <CardType>MC</CardType>
                        <AVSRsltText>AVS Not Requested.</AVSRsltText>
                     </CreditSale>
                  </Transaction>
               </Ver1.0>
            </PosResponse>
         </soap:Body>
      </soap:Envelope>
    XML
  end

  def failed_swipe_purchase_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
         <soap:Body>
            <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
               <Ver1.0>
                  <Header>
                     <LicenseId>95878</LicenseId>
                     <SiteId>95881</SiteId>
                     <DeviceId>2409000</DeviceId>
                     <GatewayTxnId>17602711</GatewayTxnId>
                     <GatewayRspCode>8</GatewayRspCode>
                     <GatewayRspMsg>Transaction was rejected because the track data could not be read.</GatewayRspMsg>
                     <RspDT>2014-05-26T10:42:44.5031513</RspDT>
                  </Header>
               </Ver1.0>
            </PosResponse>
         </soap:Body>
      </soap:Envelope>
    XML
  end

  def successful_verify_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
         <soap:Body>
            <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
               <Ver1.0>
                  <Header>
                     <LicenseId>95878</LicenseId>
                     <SiteId>95881</SiteId>
                     <DeviceId>2409000</DeviceId>
                     <SiteTrace />
                     <GatewayTxnId>20153225</GatewayTxnId>
                     <GatewayRspCode>0</GatewayRspCode>
                     <GatewayRspMsg>Success</GatewayRspMsg>
                     <RspDT>2014-09-04T14:43:49.6015895</RspDT>
                  </Header>
                  <Transaction>
                     <CreditAccountVerify>
                        <RspCode>85</RspCode>
                        <RspText>CARD OK</RspText>
                        <AuthCode>65557A</AuthCode>
                        <AVSRsltCode>0</AVSRsltCode>
                        <CVVRsltCode>M</CVVRsltCode>
                        <RefNbr>424715929580</RefNbr>
                        <CardType>Visa</CardType>
                        <AVSRsltText>AVS Not Requested.</AVSRsltText>
                        <CVVRsltText>Match.</CVVRsltText>
                     </CreditAccountVerify>
                  </Transaction>
               </Ver1.0>
            </PosResponse>
         </soap:Body>
      </soap:Envelope>
    XML
  end

  def failed_verify_response
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
         <soap:Body>
            <PosResponse xmlns="http://Hps.Exchange.PosGateway" rootUrl="https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway">
               <Ver1.0>
                  <Header>
                     <LicenseId>95878</LicenseId>
                     <SiteId>95881</SiteId>
                     <DeviceId>2409000</DeviceId>
                     <SiteTrace />
                     <GatewayTxnId>20155097</GatewayTxnId>
                     <GatewayRspCode>14</GatewayRspCode>
                     <GatewayRspMsg>Transaction rejected because the manually entered card number is invalid.</GatewayRspMsg>
                     <RspDT>2014-09-04T15:42:47.983634</RspDT>
                  </Header>
               </Ver1.0>
            </PosResponse>
         </soap:Body>
      </soap:Envelope>
    XML
  end

  def pre_scrub
    %q{
opening connection to posgateway.cert.secureexchange.net:443...
opened
starting SSL for posgateway.cert.secureexchange.net:443...
SSL established
<- "POST /Hps.Exchange.PosGateway/PosGatewayService.asmx?wsdl HTTP/1.1\r\nContent-Type: text/xml\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: posgateway.cert.secureexchange.net\r\nContent-Length: 1295\r\n\r\n"
<- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SOAP:Envelope xmlns:SOAP=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:hps=\"http://Hps.Exchange.PosGateway\"><SOAP:Body><hps:PosRequest><hps:Ver1.0><hps:Header><hps:SecretAPIKey>skapi_cert_MYl2AQAowiQAbLp5JesGKh7QFkcizOP2jcX9BrEMqQ</hps:SecretAPIKey></hps:Header><hps:Transaction><hps:CreditSale><hps:Block1><hps:Amt>1.00</hps:Amt><hps:AllowDup>Y</hps:AllowDup><hps:CardHolderData><hps:CardHolderFirstName>Longbob</hps:CardHolderFirstName><hps:CardHolderLastName>Longsen</hps:CardHolderLastName><hps:CardHolderAddr>456 My Street</hps:CardHolderAddr><hps:CardHolderCity>Ottawa</hps:CardHolderCity><hps:CardHolderState>ON</hps:CardHolderState><hps:CardHolderZip>K1C2N6</hps:CardHolderZip></hps:CardHolderData><hps:AdditionalTxnFields><hps:Description>Store Purchase</hps:Description><hps:InvoiceNbr>1</hps:InvoiceNbr></hps:AdditionalTxnFields><hps:CardData><hps:ManualEntry><hps:CardNbr>4000100011112224</hps:CardNbr><hps:ExpMonth>9</hps:ExpMonth><hps:ExpYear>2019</hps:ExpYear><hps:CVV2>123</hps:CVV2><hps:CardPresent>N</hps:CardPresent><hps:ReaderPresent>N</hps:ReaderPresent></hps:ManualEntry><hps:TokenRequest>N</hps:TokenRequest></hps:CardData><hps:SecureECommerce><hps:PaymentDataSource>ApplePay</hps:PaymentDataSource><hps:TypeOfPaymentData>3DSecure</hps:TypeOfPaymentData><hps:PaymentData>EHuWW9PiBkWvqE5juRwDzAUFBAk</hps:PaymentData><hps:ECommerceIndicator>5</hps:ECommerceIndicator><hps:XID>abc123</hps:XID</hps:SecureECommerce></hps:Block1></hps:CreditSale></hps:Transaction></hps:Ver1.0></hps:PosRequest></SOAP:Body></SOAP:Envelope>"
-> "HTTP/1.1 200 OK\r\n"
-> "Cache-Control: private, max-age=0\r\n"
-> "Content-Type: text/xml; charset=utf-8\r\n"
-> "Server: Microsoft-IIS/7.5\r\n"
-> "X-dynaTrace: PT=266421;PA=-1324159421;SP=Gateway Cert;PS=1926692524\r\n"
-> "dynaTrace: PT=266421;PA=-1324159421;SP=Gateway Cert;PS=1926692524\r\n"
-> "X-AspNet-Version: 4.0.30319\r\n"
-> "X-Powered-By: ASP.NET\r\n"
-> "X-Frame-Options: DENY\r\n"
-> "X-Content-Type-Options: nosniff\r\n"
-> "Date: Mon, 08 Jan 2018 16:28:18 GMT\r\n"
-> "Connection: close\r\n"
-> "Content-Length: 1067\r\n"
-> "\r\n"
reading 1067 bytes...
-> "<?xml version=\"1.0\" encoding=\"utf-8\"?><soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\"><soap:Body><PosResponse rootUrl=\"https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway\" xmlns=\"http://Hps.Exchange.PosGateway\"><Ver1.0><Header><LicenseId>95878</LicenseId><SiteId>95881</SiteId><DeviceId>2409000</DeviceId><GatewayTxnId>1035967766</GatewayTxnId><GatewayRspCode>0</GatewayRspCode><GatewayRspMsg>Success</GatewayRspMsg><RspDT>2018-01-08T10:28:18.5555936</RspDT></Header><Transaction><CreditSale><RspCode>00</RspCode><RspText>APPROVAL</RspText><AuthCode>64349A</AuthCode><AVSRsltCode>0</AVSRsltCode><CVVRsltCode>M</CVVRsltCode><RefNbr>800818231451</RefNbr><AVSResultCodeActi"
-> "on>ACCEPT</AVSResultCodeAction><CVVResultCodeAction>ACCEPT</CVVResultCodeAction><CardType>Visa</CardType><AVSRsltText>AVS Not Requested.</AVSRsltText><CVVRsltText>Match.</CVVRsltText></CreditSale></Transaction></Ver1.0></PosResponse></soap:Body></soap:Envelope>"
read 1067 bytes
Conn close
    }
  end

  def post_scrub
    %q{
opening connection to posgateway.cert.secureexchange.net:443...
opened
starting SSL for posgateway.cert.secureexchange.net:443...
SSL established
<- "POST /Hps.Exchange.PosGateway/PosGatewayService.asmx?wsdl HTTP/1.1\r\nContent-Type: text/xml\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: posgateway.cert.secureexchange.net\r\nContent-Length: 1295\r\n\r\n"
<- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SOAP:Envelope xmlns:SOAP=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:hps=\"http://Hps.Exchange.PosGateway\"><SOAP:Body><hps:PosRequest><hps:Ver1.0><hps:Header><hps:SecretAPIKey>[FILTERED]</hps:SecretAPIKey></hps:Header><hps:Transaction><hps:CreditSale><hps:Block1><hps:Amt>1.00</hps:Amt><hps:AllowDup>Y</hps:AllowDup><hps:CardHolderData><hps:CardHolderFirstName>Longbob</hps:CardHolderFirstName><hps:CardHolderLastName>Longsen</hps:CardHolderLastName><hps:CardHolderAddr>456 My Street</hps:CardHolderAddr><hps:CardHolderCity>Ottawa</hps:CardHolderCity><hps:CardHolderState>ON</hps:CardHolderState><hps:CardHolderZip>K1C2N6</hps:CardHolderZip></hps:CardHolderData><hps:AdditionalTxnFields><hps:Description>Store Purchase</hps:Description><hps:InvoiceNbr>1</hps:InvoiceNbr></hps:AdditionalTxnFields><hps:CardData><hps:ManualEntry><hps:CardNbr>[FILTERED]</hps:CardNbr><hps:ExpMonth>9</hps:ExpMonth><hps:ExpYear>2019</hps:ExpYear><hps:CVV2>[FILTERED]</hps:CVV2><hps:CardPresent>N</hps:CardPresent><hps:ReaderPresent>N</hps:ReaderPresent></hps:ManualEntry><hps:TokenRequest>N</hps:TokenRequest></hps:CardData><hps:SecureECommerce><hps:PaymentDataSource>ApplePay</hps:PaymentDataSource><hps:TypeOfPaymentData>3DSecure</hps:TypeOfPaymentData><hps:PaymentData>[FILTERED]</hps:PaymentData><hps:ECommerceIndicator>5</hps:ECommerceIndicator><hps:XID>abc123</hps:XID</hps:SecureECommerce></hps:Block1></hps:CreditSale></hps:Transaction></hps:Ver1.0></hps:PosRequest></SOAP:Body></SOAP:Envelope>"
-> "HTTP/1.1 200 OK\r\n"
-> "Cache-Control: private, max-age=0\r\n"
-> "Content-Type: text/xml; charset=utf-8\r\n"
-> "Server: Microsoft-IIS/7.5\r\n"
-> "X-dynaTrace: PT=266421;PA=-1324159421;SP=Gateway Cert;PS=1926692524\r\n"
-> "dynaTrace: PT=266421;PA=-1324159421;SP=Gateway Cert;PS=1926692524\r\n"
-> "X-AspNet-Version: 4.0.30319\r\n"
-> "X-Powered-By: ASP.NET\r\n"
-> "X-Frame-Options: DENY\r\n"
-> "X-Content-Type-Options: nosniff\r\n"
-> "Date: Mon, 08 Jan 2018 16:28:18 GMT\r\n"
-> "Connection: close\r\n"
-> "Content-Length: 1067\r\n"
-> "\r\n"
reading 1067 bytes...
-> "<?xml version=\"1.0\" encoding=\"utf-8\"?><soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\"><soap:Body><PosResponse rootUrl=\"https://posgateway.cert.secureexchange.net/Hps.Exchange.PosGateway\" xmlns=\"http://Hps.Exchange.PosGateway\"><Ver1.0><Header><LicenseId>95878</LicenseId><SiteId>95881</SiteId><DeviceId>2409000</DeviceId><GatewayTxnId>1035967766</GatewayTxnId><GatewayRspCode>0</GatewayRspCode><GatewayRspMsg>Success</GatewayRspMsg><RspDT>2018-01-08T10:28:18.5555936</RspDT></Header><Transaction><CreditSale><RspCode>00</RspCode><RspText>APPROVAL</RspText><AuthCode>64349A</AuthCode><AVSRsltCode>0</AVSRsltCode><CVVRsltCode>M</CVVRsltCode><RefNbr>800818231451</RefNbr><AVSResultCodeActi"
-> "on>ACCEPT</AVSResultCodeAction><CVVResultCodeAction>ACCEPT</CVVResultCodeAction><CardType>Visa</CardType><AVSRsltText>AVS Not Requested.</AVSRsltText><CVVRsltText>Match.</CVVRsltText></CreditSale></Transaction></Ver1.0></PosResponse></soap:Body></soap:Envelope>"
read 1067 bytes
Conn close
    }
  end

  def pre_scrubbed_account_number
    <<~PRE_SCRUBBED
      opening connection to posgateway.secureexchange.net:443...
      opened
      starting SSL for posgateway.secureexchange.net:443...
      SSL established, protocol: TLSv1.2, cipher: DHE-RSA-AES256-SHA256
      <- "POST /Hps.Exchange.PosGateway/PosGatewayService.asmx?wsdl HTTP/1.1\r\nContent-Type: text/xml\r\nConnection: close\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nHost: posgateway.secureexchange.net\r\nContent-Length: 1029\r\n\r\n"
      <- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SOAP:Envelope xmlns:SOAP=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:hps=\"http://Hps.Exchange.PosGateway\"><SOAP:Body><hps:PosRequest><hps:Ver1.0><hps:Header><hps:SecretAPIKey/></hps:Header><hps:Transaction><hps:CheckSale><hps:Block1><hps:CheckAction>SALE</hps:CheckAction><hps:AccountInfo><hps:RoutingNumber>122000030</hps:RoutingNumber><hps:AccountNumber>1357902468</hps:AccountNumber><hps:CheckNumber>1234</hps:CheckNumber><hps:AccountType>SAVINGS</hps:AccountType></hps:AccountInfo><hps:CheckType>PERSONAL</hps:CheckType><hps:Amt>20.00</hps:Amt><hps:SECCode>WEB</hps:SECCode><hps:ConsumerInfo><hps:FirstName>Jim</hps:FirstName><hps:LastName>Smith</hps:LastName><hps:CheckName>Hot Buttered Toast Incorporated</hps:CheckName></hps:ConsumerInfo><hps:AdditionalTxnFields><hps:Description>Store Purchase</hps:Description><hps:InvoiceNbr>1</hps:InvoiceNbr></hps:AdditionalTxnFields></hps:Block1></hps:CheckSale></hps:Transaction></hps:Ver1.0></hps:PosRequest></SOAP:Body></SOAP:Envelope>"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Cache-Control: no-cache,no-store\r\n"
      -> "Pragma: no-cache\r\n"
      -> "Content-Type: text/xml; charset=utf-8\r\n"
      -> "Expires: -1\r\n"
      -> "X-Frame-Options: DENY\r\n"
      -> "X-Content-Type-Options: nosniff\r\n"
      -> "Strict-Transport-Security: max-age=31536000; includeSubDomains;\r\n"
      -> "Date: Tue, 12 Oct 2021 15:17:29 GMT\r\n"
      -> "Connection: close\r\n"
      -> "Content-Length: 543\r\n"
      -> "\r\n"
      reading 543 bytes...
      -> "<?xml version=\"1.0\" encoding=\"utf-8\"?><soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\"><soap:Body><PosResponse rootUrl=\"https://posgateway.secureexchange.net/Hps.Exchange.PosGateway\" xmlns=\"http://Hps.Exchange.PosGateway\"><Ver1.0><Header><GatewayTxnId>1589181322</GatewayTxnId><GatewayRspCode>-2</GatewayRspCode><GatewayRspMsg>Authentication Error</GatewayRspMsg></Header></Ver1.0></PosResponse></soap:Body></soap:Envelope>"
      read 543 bytes
      Conn close
    PRE_SCRUBBED
  end

  def post_scrubbed_account_number
    <<~POST_SCRUBBED
      opening connection to posgateway.secureexchange.net:443...
      opened
      starting SSL for posgateway.secureexchange.net:443...
      SSL established, protocol: TLSv1.2, cipher: DHE-RSA-AES256-SHA256
      <- "POST /Hps.Exchange.PosGateway/PosGatewayService.asmx?wsdl HTTP/1.1\r\nContent-Type: text/xml\r\nConnection: close\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nHost: posgateway.secureexchange.net\r\nContent-Length: 1029\r\n\r\n"
      <- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SOAP:Envelope xmlns:SOAP=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:hps=\"http://Hps.Exchange.PosGateway\"><SOAP:Body><hps:PosRequest><hps:Ver1.0><hps:Header><hps:SecretAPIKey/></hps:Header><hps:Transaction><hps:CheckSale><hps:Block1><hps:CheckAction>SALE</hps:CheckAction><hps:AccountInfo><hps:RoutingNumber>[FILTERED]</hps:RoutingNumber><hps:AccountNumber>[FILTERED]</hps:AccountNumber><hps:CheckNumber>1234</hps:CheckNumber><hps:AccountType>SAVINGS</hps:AccountType></hps:AccountInfo><hps:CheckType>PERSONAL</hps:CheckType><hps:Amt>20.00</hps:Amt><hps:SECCode>WEB</hps:SECCode><hps:ConsumerInfo><hps:FirstName>Jim</hps:FirstName><hps:LastName>Smith</hps:LastName><hps:CheckName>Hot Buttered Toast Incorporated</hps:CheckName></hps:ConsumerInfo><hps:AdditionalTxnFields><hps:Description>Store Purchase</hps:Description><hps:InvoiceNbr>1</hps:InvoiceNbr></hps:AdditionalTxnFields></hps:Block1></hps:CheckSale></hps:Transaction></hps:Ver1.0></hps:PosRequest></SOAP:Body></SOAP:Envelope>"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Cache-Control: no-cache,no-store\r\n"
      -> "Pragma: no-cache\r\n"
      -> "Content-Type: text/xml; charset=utf-8\r\n"
      -> "Expires: -1\r\n"
      -> "X-Frame-Options: DENY\r\n"
      -> "X-Content-Type-Options: nosniff\r\n"
      -> "Strict-Transport-Security: max-age=31536000; includeSubDomains;\r\n"
      -> "Date: Tue, 12 Oct 2021 15:17:29 GMT\r\n"
      -> "Connection: close\r\n"
      -> "Content-Length: 543\r\n"
      -> "\r\n"
      reading 543 bytes...
      -> "<?xml version=\"1.0\" encoding=\"utf-8\"?><soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\"><soap:Body><PosResponse rootUrl=\"https://posgateway.secureexchange.net/Hps.Exchange.PosGateway\" xmlns=\"http://Hps.Exchange.PosGateway\"><Ver1.0><Header><GatewayTxnId>1589181322</GatewayTxnId><GatewayRspCode>-2</GatewayRspCode><GatewayRspMsg>Authentication Error</GatewayRspMsg></Header></Ver1.0></PosResponse></soap:Body></soap:Envelope>"
      read 543 bytes
      Conn close
    POST_SCRUBBED
  end
end
