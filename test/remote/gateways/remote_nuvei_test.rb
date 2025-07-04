require 'test_helper'
require 'timecop'

class RemoteNuveiTest < Test::Unit::TestCase
  def setup
    @gateway = NuveiGateway.new(fixtures(:nuvei))

    @amount = 10000
    @credit_card = credit_card('4761344136141390', verification_value: '999', first_name: 'Cure', last_name: 'Tester')
    @declined_card = credit_card('4000128449498204')
    @challenge_credit_card = credit_card('2221008123677736', first_name: 'CL-BRW2', last_name: '')
    @three_ds_amount = 151 # for challenge = 151, for frictionless >= 150
    @frictionless_credit_card = credit_card('4000020951595032', first_name: 'FL-BRW2', last_name: '')
    @credit_card_3ds = credit_card('4000020951595032')

    @options = {
      email: 'test@gmail.com',
      billing_address: address.merge(name: 'Cure Tester'),
      ip: '127.0.0.1',
      order_id: '123456'
    }

    @user_details_options = @options.merge({
      user_details: {
        first_name: 'first',
        last_name: 'last',
        street_number: '1234',
        address: '123 address',
        phone: '123456789',
        zip: '12345',
        city: 'city',
        country: 'US',
        state: 'CA',
        email: 'test@test.com',
        county: 'county',
        language: 'US',
        identification: '12345667'
      }
    })

    @three_ds_options = {
      execute_threed: true,
      redirect_url: 'http://www.example.com/redirect',
      callback_url: 'http://www.example.com/callback',
      three_ds_2: {
        browser_info:  {
          width: 390,
          height: 400,
          depth: 24,
          timezone: 300,
          user_agent: 'Spreedly Agent',
          java: false,
          javascript: true,
          language: 'en-US',
          browser_size: '05',
          accept_header: 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8'
        }
      }
    }

    @bank_account = check(account_number: '111111111', routing_number: '999999992')

    @three_d_secure_options = @options.merge({
      three_d_secure: {
        cavv: 'jJ81HADVRtXfCBATEp01CJUAAAA=',
        ds_transaction_id: '97267598-FAE6-48F2-8083-C23433990FBC',
        eci: '05'
      }
    })

    @apple_pay_card = network_tokenization_credit_card(
      '5204245250460049',
      payment_cryptogram: 'EHuWW9PiBkWvqE5juRwDzAUFBAk=',
      month: '12',
      year: Time.new.year + 2,
      source: :apple_pay,
      verification_value: 111,
      eci: '5'
    )

    @google_pay_card = network_tokenization_credit_card(
      '4761344136141390',
      payment_cryptogram: 'YwAAAAAABaYcCMX/OhNRQAAAAAA=',
      month: '12',
      year: Time.new.year + 2,
      source: :google_pay,
      eci: '5'
    )
  end

  def test_transcript_scrubbing
    transcript = capture_transcript(@gateway) do
      @gateway.authorize(@amount, @credit_card, @options)
    end

    @gateway.scrub(transcript)
  end

  def test_successful_session_token_generation
    response = @gateway.send(:fetch_session_token, @options)
    assert_success response
    assert_not_nil response.params[:sessionToken]
  end

  def test_failed_session_token_generation
    @gateway.options[:merchant_site_id] = 123
    response = @gateway.send(:fetch_session_token, {})
    assert_failure response
    assert_match 'Invalid merchant site id', response.message
  end

  def test_successful_authorize
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert_equal response.params[:clientUniqueId], @options[:order_id]
    assert_not_nil response.params[:orderId]
    assert_not_nil response.params[:transactionId]
    assert_match 'APPROVED', response.message
  end

  def test_successful_authorize_without_order_id
    @options.delete(:order_id)
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert_not_nil response.params[:clientUniqueId]
    assert_not_nil response.params[:transactionId]
    assert_match 'APPROVED', response.message
  end

  def test_failed_authorize
    response = @gateway.authorize(@amount, @declined_card, @options)
    assert_failure response
    assert_match 'DECLINED', response.params['transactionStatus']
  end

  def test_successful_authorize_and_capture
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response

    capture_response = @gateway.capture(round_down(@amount).to_i, response.authorization)

    assert_success capture_response
    assert_match 'APPROVED', capture_response.message
  end

  def test_successful_zero_auth
    response = @gateway.authorize(0, @credit_card, @options)
    assert_success response
    assert_match 'APPROVED', response.message
  end

  def test_successful_purchase
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal response.params[:clientUniqueId], @options[:order_id]
    assert_not_nil response.params[:orderId]
    assert_not_nil response.params[:transactionId]
    assert_match 'APPROVED', response.message
    assert_match 'SUCCESS', response.params['status']
  end

  def test_successful_purchase_with_3ds_frictionless
    response = @gateway.purchase(@three_ds_amount, @frictionless_credit_card, @options.merge(@three_ds_options))
    assert_success response
    assert_not_nil response.params[:transactionId]
    assert_match 'SUCCESS', response.params['status']
    assert_match 'APPROVED', response.message
  end

  def test_successful_purchase_with_3ds_challenge
    response = @gateway.purchase(@three_ds_amount, @challenge_credit_card, @options.merge(@three_ds_options))
    assert_success response
    assert_not_nil response.params[:transactionId]
    assert_match 'SUCCESS', response.params['status']
    assert_match 'APPROVED', response.message
  end

  def test_successful_purchase_with_not_enrolled_card
    response = @gateway.purchase(@three_ds_amount, @credit_card, @options.merge(@three_ds_options))
    assert_success response
    assert_not_nil response.params[:transactionId]
    assert_match 'SUCCESS', response.params['status']
    assert_match 'APPROVED', response.message
  end

  def test_successful_purchase_with_3ds_frictionless_and_forced_3ds
    response = @gateway.purchase(@three_ds_amount, @frictionless_credit_card, @options.merge(@three_ds_options.merge({ force_3d_secure: true })))
    assert_success response
    assert_not_nil response.params[:transactionId]
    assert_match 'SUCCESS', response.params['status']
    assert_match 'APPROVED', response.message
  end

  def test_successful_purchase_with_not_enrolled_card_and_forced_3ds
    response = @gateway.purchase(@three_ds_amount, @credit_card, @options.merge(@three_ds_options.merge({ force_3d_secure: true })))
    assert_failure response
    assert_equal response.message, '3D Secure is required but not supported'
  end

  def test_failed_purchase
    response = @gateway.purchase(@amount, @declined_card, @options)
    assert_failure response
    assert_match 'DECLINED', response.params['transactionStatus']
  end

  def test_failed_purchase_with_invalid_cvv
    @credit_card.verification_value = ''
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_failure response
    assert_match 'ERROR', response.params['status']
    assert_match 'cardData.CVV is invalid', response.message
  end

  def test_failed_capture_invalid_transaction_id
    response = @gateway.capture(@amount, '123')
    assert_failure response
    assert_match 'ERROR', response.params['status']
    assert_match 'Invalid relatedTransactionId', response.message
  end

  def test_successful_void
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response

    void_response = @gateway.void(response.authorization)
    assert_success void_response
    assert_match 'SUCCESS', void_response.params['status']
    assert_match 'APPROVED', void_response.message
  end

  def test_failed_void_invalid_transaction_id
    response = @gateway.void('123')
    assert_failure response
    assert_match 'ERROR', response.params['status']
    assert_match 'Invalid relatedTransactionId', response.message
  end

  def test_successful_refund
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response

    refund_response = @gateway.refund(@amount, response.authorization)
    assert_success refund_response
    assert_match 'SUCCESS', refund_response.params['status']
    assert_match 'APPROVED', refund_response.message
  end

  def test_successful_refund_with_order_id
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response

    refund_response = @gateway.refund(@amount, response.authorization, options = { order_id: response.params['clientUniqueId'] })
    assert_success refund_response
    assert_equal response.params['clientUniqueId'], options[:order_id]
    assert_match 'SUCCESS', refund_response.params['status']
    assert_match 'APPROVED', refund_response.message
  end

  def test_successful_verify
    response = @gateway.verify(@credit_card, @options)
    assert_success response
    assert_match 'SUCCESS', response.params['status']
    assert_match 'APPROVED', response.message
  end

  def test_successful_save_payment_method_override
    response = @gateway.purchase(@amount, @credit_card, @options.merge(save_payment_method: false))
    assert_success response
    assert_match 'SUCCESS', response.params['status']
    assert_match 'APPROVED', response.message
    assert_not_nil response.params[:paymentOption][:userPaymentOptionId]
  end

  def test_successful_verify_with_authentication_only_type
    response = @gateway.verify(@credit_card, @options.merge({ authentication_only_type: 'MAINTAINCARD' }))
    assert_match 'SUCCESS', response.params['status']
    assert_match 'APPROVED', response.message
  end

  def test_successful_unreferenced_refund
    refund_response = @gateway.credit(@amount, @credit_card, @options.merge(user_token_id: '12345678'))
    assert_success refund_response
    assert_match 'SUCCESS', refund_response.params['status']
    assert_match 'APPROVED', refund_response.message
  end

  def test_successful_unreferenced_refund_with_user_option_id
    # getting the user_option_id from prevouse purchase
    purchase_response = @gateway.purchase(@amount, @credit_card, @options.merge(user_token_id: '12345678'))
    assert_success purchase_response

    user_payment_id = purchase_response.params[:paymentOption][:userPaymentOptionId]

    refund_response = @gateway.credit(@amount, @credit_card, @options.merge(user_token_id: '12345678', user_payment_option_id: user_payment_id))
    assert_success refund_response
    assert_match 'SUCCESS', refund_response.params['status']
    assert_match 'APPROVED', refund_response.message
  end

  def test_successful_payout
    payout_response = @gateway.credit(@amount, @credit_card, @options.merge(user_token_id: '12345678', is_payout: true))
    assert_success payout_response
    assert_match 'SUCCESS', payout_response.params['status']
    assert_match 'APPROVED', payout_response.message
  end

  def test_successful_payout_with_oct_user_details
    @user_details_options[:user_details][:birth_date] = '1990-09-01'
    @user_details_options[:user_details].delete(:language)
    @user_details_options[:user_details].delete(:county)
    @user_details_options[:user_details].delete(:street_number)
    payout_response = @gateway.credit(@amount, @credit_card, @user_details_options.merge(user_token_id: '12345678', is_payout: true))
    assert_success payout_response
    assert_match 'SUCCESS', payout_response.params['status']
    assert_match 'APPROVED', payout_response.message
  end

  def test_successful_payout_with_google_pay
    purchase_response = @gateway.purchase(@amount, @credit_card, @options.merge(user_token_id: '12345678'))
    assert_success purchase_response
    user_payment_id = purchase_response.params[:paymentOption][:userPaymentOptionId]

    options = @options.merge(
      user_payment_option_id: user_payment_id,
      user_token_id: '12345678',
      is_payout: true,
      notification_url: 'https://example.com/notification'
    )
    payout_response = @gateway.credit(@amount, @google_pay_card, options)
    assert_success payout_response
    assert_match 'SUCCESS', payout_response.params['status']
    assert_match 'APPROVED', payout_response.message
  end

  def test_failed_unreferenced_refund
    refund_response = @gateway.credit(@amount, @declined_card, @options.merge(user_token_id: '12345678'))
    assert_failure refund_response

    assert_match 'DECLINED', refund_response.params['transactionStatus']
    assert_match 'External Error in Processing', refund_response.message
  end

  def test_failed_payout
    payout_response = @gateway.credit(@amount, @declined_card, @options.merge(user_token_id: '12345678'))
    assert_failure payout_response

    assert_match 'DECLINED', payout_response.params['transactionStatus']
    assert_match 'External Error in Processing', payout_response.message
  end

  def test_successful_store
    response = @gateway.store(@credit_card, @options.merge(user_token_id: '12345678'))
    assert_success response
    assert_match 'SUCCESS', response.params['status']
    assert_match 'APPROVED', response.message
  end

  def test_purchase_using_stored_credentials_cit
    options = @options.merge!(user_token_id: '12345678', stored_credential: stored_credential(:cardholder, :unscheduled, :initial))
    assert response = @gateway.authorize(@amount, @credit_card, options)
    assert_success response

    assert capture = @gateway.capture(round_down(@amount).to_i, response.authorization, @options)
    assert_success capture

    options_stored_credentials = @options.merge!(stored_credential: stored_credential(:cardholder, :recurring, id: response.network_transaction_id))
    assert purchase_response = @gateway.purchase(@amount, @credit_card, options_stored_credentials)
    assert_success purchase_response
  end

  def test_purchase_using_stored_credentials_recurring_cit
    # Initial transaction with stored credentials
    initial_options = @options.merge(user_token_id: '12345678', stored_credential: stored_credential(:cardholder, :unscheduled, :initial))
    initial_response = @gateway.purchase(@amount, @credit_card, initial_options)
    assert_success initial_response

    assert_not_nil initial_response.authorization
    assert_match 'SUCCESS', initial_response.params['status']

    stored_credential_options = @options.merge(
      user_token_id: '12345678',
      stored_credential: stored_credential(:merchant, :recurring, network_transaction_id: initial_response.network_transaction_id)
    )

    recurring_response = @gateway.purchase(@amount, @credit_card, stored_credential_options)
    assert_success recurring_response
    assert_match 'SUCCESS', recurring_response.params['status']
  end

  def test_purchase_using_stored_credentials_merchant_installments_cit
    initial_options = @options.merge(user_token_id: '12345678', stored_credential: stored_credential(:cardholder, :unscheduled, :initial))
    initial_response = @gateway.purchase(@amount, @credit_card, initial_options)
    assert_success initial_response

    assert_not_nil initial_response.authorization
    assert_match 'SUCCESS', initial_response.params['status']

    stored_credential_options = @options.merge(
      user_token_id: '12345678',
      stored_credential: stored_credential(:merchant, :installments, network_transaction_id: initial_response.network_transaction_id)
    )

    recurring_response = @gateway.purchase(@amount, @credit_card, stored_credential_options)
    assert_success recurring_response
    assert_match 'SUCCESS', recurring_response.params['status']
  end

  def test_purchase_subsequent_init_mit
    initial_options = @options.merge(user_token_id: '12345678', stored_credential: stored_credential(:merchant, :unscheduled, :initial))
    initial_response = @gateway.purchase(@amount, @credit_card, initial_options)
    assert_success initial_response

    subsequent_options = @options.merge(user_token_id: '12345678', stored_credential: stored_credential(:merchant, :recurring, network_transaction_id: initial_response.authorization))
    subsequent_response = @gateway.purchase(@amount, @credit_card, subsequent_options)
    assert_success subsequent_response
    assert_match 'SUCCESS', subsequent_response.params['status']
  end

  def test_successful_purchase_subsequent_mit
    initial_options = @options.merge(user_token_id: '12345678', stored_credential: stored_credential(:merchant, :unscheduled, :initial))
    initial_response = @gateway.purchase(@amount, @credit_card, initial_options)
    assert_success initial_response

    subsequent_options = @options.merge(user_token_id: '12345678', stored_credential: stored_credential(:merchant, :recurring, network_transaction_id: initial_response.authorization))
    subsequent_response = @gateway.purchase(@amount, @credit_card, subsequent_options.merge(is_rebilling: true))
    assert_success subsequent_response
    assert_match 'SUCCESS', subsequent_response.params['status']
  end

  def test_successful_partial_approval
    response = @gateway.authorize(55, @credit_card, @options.merge(is_partial_approval: true))
    assert_success response
    assert_equal '0.55', response.params['partialApproval']['requestedAmount']
    assert_equal '0.55', response.params['partialApproval']['processedAmount']
    assert_match 'APPROVED', response.message
  end

  def test_successful_authorize_with_bank_account
    @options.update(billing_address: address.merge(country: 'US', state: 'MA'))
    response = @gateway.authorize(1.25, @bank_account, @options)
    assert_success response
    assert_match 'PENDING', response.message
  end

  def test_failing_purchase_three_d_secure
    @three_d_secure_options[:three_d_secure][:cavv] = 'wrong_cavv_value'
    assert response = @gateway.purchase(@amount, @credit_card_3ds, @three_d_secure_options)
    assert_failure response
    assert_equal 'UNEXPECTED SYSTEM ERROR - PLEASE RETRY LATER', response.message
    assert_match 'ERROR', response.params['transactionStatus']
  end

  def test_successful_purchase_with_three_d_secure
    assert response = @gateway.purchase(@amount, @credit_card_3ds, @three_d_secure_options)
    assert_success response
    assert response.authorization
    assert_equal 'APPROVED', response.message
    assert_match 'SUCCESS', response.params['status']
  end

  def test_successful_purchase_three_d_secure_challenge_preference
    assert response = @gateway.purchase(@amount, @credit_card_3ds, @three_d_secure_options.merge(challenge_preference: 'ExemptionRequest', exemption_request_reason: 'AccountVerification'))
    assert_success response
    assert_equal 'APPROVED', response.message
    assert_match 'SUCCESS', response.params['status']
    assert response.authorization
  end

  def test_successful_purchase_with_apple_pay
    response = @gateway.purchase(@amount, @apple_pay_card, @options)
    assert_success response
    assert_equal 'APPROVED', response.message
    assert_not_nil response.params[:paymentOption][:userPaymentOptionId]
  end

  def test_successful_purchase_with_google_pay
    response = @gateway.purchase(@amount, @google_pay_card, @options)
    assert_success response
    assert_equal 'APPROVED', response.message
    assert_not_nil response.params[:paymentOption][:userPaymentOptionId]
  end

  def test_purchase_account_funding_transaction
    response = @gateway.purchase(@amount, @credit_card, @options.merge(is_aft: true, aft_recipient_first_name: 'John', aft_recipient_last_name: 'Doe'))
    assert_success response
    assert_equal 'APPROVED', response.message
  end

  def test_successful_authorize_with_aft_user_details
    @user_details_options[:user_details][:date_of_birth] = '1990-09-01'
    response = @gateway.authorize(@amount, @credit_card, @user_details_options.merge(is_aft: true, aft_recipient_first_name: 'John', aft_recipient_last_name: 'Doe'))
    assert_success response
    assert_match 'APPROVED', response.message
  end

  def test_refund_account_funding_transaction
    purchase_response = @gateway.purchase(@amount, @credit_card, @options.merge(is_aft: true, aft_recipient_first_name: 'John', aft_recipient_last_name: 'Doe'))
    assert_success purchase_response

    refund_response = @gateway.refund(@amount, purchase_response.authorization)
    assert_success refund_response
    assert_equal 'APPROVED', refund_response.message
  end

  def test_successful_authorize_with_cardholder_name_verification
    response = @gateway.authorize(0, @credit_card, @options.merge({ perform_name_verification: true }))
    assert_success response
    assert_match 'APPROVED', response.message
  end

  def test_capture_sends_order_id_as_client_unique_id
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    capture_response = @gateway.capture(@amount, response.authorization, @options.merge(order_id: '2233512890'))
    assert_success capture_response
    assert_equal '2233512890', capture_response.params['clientUniqueId']
    assert_success capture_response
    assert_match 'APPROVED', capture_response.message
  end

  def round_down(value, decimals = 1)
    value = value.to_f / 2
    factor = 10**decimals
    ((value * factor).floor / factor.to_f).to_s
  end
end
