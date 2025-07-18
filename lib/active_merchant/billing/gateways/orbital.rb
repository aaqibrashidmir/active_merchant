require 'active_merchant/billing/gateways/orbital/orbital_soft_descriptors'
require 'rexml/document'
require 'active_merchant/billing/gateways/orbital/orbital_codes'

module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    # For more information on Orbital, visit the {integration center}[http://download.chasepaymentech.com]
    #
    # ==== Authentication Options
    #
    # The Orbital Gateway supports two methods of authenticating incoming requests:
    # Source IP authentication and Connection Username/Password authentication
    #
    # In addition, these IP addresses/Connection Usernames must be affiliated with the Merchant IDs
    # for which the client should be submitting transactions.
    #
    # This does allow Third Party Hosting service organizations presenting on behalf of other
    # merchants to submit transactions.  However, each time a new customer is added, the
    # merchant or Third-Party hosting organization needs to ensure that the new Merchant IDs
    # or Chain IDs are affiliated with the hosting companies IPs or Connection Usernames.
    #
    # If the merchant expects to have more than one merchant account with the Orbital
    # Gateway, it should have its IP addresses/Connection Usernames affiliated at the Chain
    # level hierarchy within the Orbital Gateway.  Each time a new merchant ID is added, as
    # long as it is placed within the same Chain, it will simply work.  Otherwise, the additional
    # MIDs will need to be affiliated with the merchant IPs or Connection Usernames respectively.
    # For example, we generally affiliate all Salem accounts [BIN 000001] with
    # their Company Number [formerly called MA #] number so all MIDs or Divisions under that
    # Company will automatically be affiliated.

    class OrbitalGateway < Gateway
      include OrbitalCodes
      include Empty

      version '9.5'

      POST_HEADERS = {
        'MIME-Version' => '1.1',
        'Content-Type' => "application/PTI#{fetch_version.delete('.')}",
        'Content-transfer-encoding' => 'text',
        'Request-number' => '1',
        'Document-type' => 'Request',
        'Interface-Version' => 'Ruby|ActiveMerchant|Proprietary Gateway'
      }

      SUCCESS = '0'
      APPROVAL_SUCCESS = '1'

      APPROVED = [
        '00', # Approved
        '08', # Approved authorization, honor with ID
        '11', # Approved authorization, VIP approval
        '24', # Validated
        '26', # Pre-noted
        '27', # No reason to decline
        '28', # Received and stored
        '29', # Provided authorization
        '31', # Request received
        '32', # BIN alert
        '34', # Approved for partial
        '91', # Approved low fraud
        '92', # Approved medium fraud
        '93', # Approved high fraud
        '94', # Approved fraud service unavailable
        'E7', # Stored
        'PA', # Partial approval
        'P1'  # ECP - AVS - Account Status Verification and/or AOA data is in a positive status.
      ]

      class_attribute :secondary_test_url, :secondary_live_url

      self.test_url = 'https://orbitalvar1.chasepaymentech.com/authorize'
      self.secondary_test_url = 'https://orbitalvar2.chasepaymentech.com/authorize'

      self.live_url = 'https://orbital1.chasepaymentech.com/authorize'
      self.secondary_live_url = 'https://orbital2.chasepaymentech.com/authorize'

      self.supported_countries = %w[US CA]
      self.default_currency = 'CAD'
      self.supported_cardtypes = %i[visa master american_express discover diners_club jcb]

      self.display_name = 'Orbital Paymentech'
      self.homepage_url = 'http://chasepaymentech.com/'

      self.money_format = :cents

      AVS_SUPPORTED_COUNTRIES = %w[US CA UK GB]

      # INDUSTRY TYPES
      ECOMMERCE_TRANSACTION = 'EC'
      RECURRING_PAYMENT_TRANSACTION = 'RC'
      MAIL_ORDER_TELEPHONE_ORDER_TRANSACTION = 'MO'
      INTERACTIVE_VOICE_RESPONSE = 'IV'
      # INTERACTIVE_VOICE_RESPONSE = 'IN'

      # Auth Only No Capture
      AUTH_ONLY = 'A'
      # AC - Auth and Capture = 'AC'
      AUTH_AND_CAPTURE = 'AC'
      # F  - Force Auth No Capture and no online authorization = 'F'
      FORCE_AUTH_ONLY = 'F'
      # FR - Force Auth No Capture and no online authorization = 'FR'
      # FC - Force Auth and Capture no online authorization = 'FC'
      FORCE_AUTH_AND_CAPTURE = 'FC'
      # Refund and Capture no online authorization
      REFUND = 'R'

      # Tax Inds
      TAX_NOT_PROVIDED = 0
      TAX_INCLUDED     = 1
      NON_TAXABLE_TRANSACTION = 2

      # Customer Profile Actions
      CREATE   = 'C'
      RETRIEVE = 'R'
      UPDATE   = 'U'
      DELETE   = 'D'

      RECURRING = 'R'
      DEFERRED  = 'D'

      # Status
      # Profile Status Flag
      # This field is used to set the status of a Customer Profile.
      ACTIVE   = 'A'
      INACTIVE = 'I'
      MANUAL_SUSPEND = 'MS'

      # CustomerProfileOrderOverrideInd
      # Defines if any Order Data can be pre-populated from
      # the Customer Reference Number (CustomerRefNum)
      NO_MAPPING_TO_ORDER_DATA = 'NO'
      USE_CRN_FOR_ORDER_ID     = 'OI'
      USE_CRN_FOR_COMMENTS     = 'OD'
      USE_CRN_FOR_ORDER_ID_AND_COMMENTS = 'OA'

      #  CustomerProfileFromOrderInd
      # Method to use to Generate the Customer Profile Number
      # When Customer Profile Action Type = Create, defines
      # what the Customer Profile Number will be:
      AUTO_GENERATE        = 'A' # Auto-Generate the CustomerRefNum
      USE_CUSTOMER_REF_NUM = 'S' # Use CustomerRefNum field
      USE_ORDER_ID         = 'O' #  Use OrderID field
      USE_COMMENTS         = 'D' #  Use Comments field

      SENSITIVE_FIELDS = %i[account_num cc_account_num]

      # Bank account types to be used for check processing
      ACCOUNT_TYPE = {
        'savings' => 'S',
        'checking' => 'C'
      }

      # safetech token flags
      GET_TOKEN = 'GT'
      USE_TOKEN = 'UT'

      def initialize(options = {})
        requires!(options, :merchant_id)
        requires!(options, :login, :password) unless options[:ip_authentication]
        super
        @options[:merchant_id] = @options[:merchant_id].to_s
        @use_secondary_url = false
      end

      # A – Authorization request
      def authorize(money, payment_source, options = {})
        # ECP for Orbital requires $0 prenotes so ensure
        # if we are doing a force capture with a check, that
        # we do a purchase here
        return purchase(money, payment_source, options) if force_capture_with_echeck?(payment_source, options)

        order = build_new_auth_purchase_order(AUTH_ONLY, money, payment_source, options)

        commit(order, :authorize, options)
      end

      def verify(credit_card, options = {})
        amount = options[:verify_amount] ? options[:verify_amount].to_i : default_verify_amount(credit_card)
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(amount, credit_card, options) }
          r.process(:ignore_result) { void(r.authorization) } unless amount == 0
        end
      end

      # AC – Authorization and Capture
      def purchase(money, payment_source, options = {})
        action = options[:force_capture] ? FORCE_AUTH_AND_CAPTURE : AUTH_AND_CAPTURE
        order = build_new_auth_purchase_order(action, money, payment_source, options)

        commit(order, :purchase, options)
      end

      # MFC - Mark For Capture
      def capture(money, authorization, options = {})
        commit(build_mark_for_capture_xml(money, authorization, options), :capture, options)
      end

      # R – Refund request
      def refund(money, authorization, options = {})
        payment_method = options[:payment_method]
        order = build_new_order_xml(REFUND, money, payment_method, options.merge(authorization:)) do |xml|
          add_payment_source(xml, payment_method, options)
          xml.tag! :CustomerRefNum, options[:customer_ref_num] if @options[:customer_profiles] && options[:profile_txn]
        end

        commit(order, :refund, options)
      end

      def credit(money, payment_method, options = {})
        order = build_new_order_xml(REFUND, money, payment_method, options) do |xml|
          add_payment_source(xml, payment_method, options)
        end

        commit(order, :refund, options)
      end

      # Orbital save a payment method if the TokenTxnType is 'GT', that's why we use this as the default value for store
      def store(creditcard, options = {})
        options[:exp_date] = expiry_date(creditcard) if creditcard.is_a?(CreditCard)

        authorize(0, creditcard, options.merge({ token_txn_type: GET_TOKEN }))
      end

      def void(authorization, options = {}, deprecated = {})
        if !options.kind_of?(Hash)
          ActiveMerchant.deprecated('Calling the void method with an amount parameter is deprecated and will be removed in a future version.')
          return void(options, deprecated.merge(amount: authorization))
        end

        order = build_void_request_xml(authorization, options)

        commit(order, :void, options)
      end

      def default_verify_amount(credit_card)
        allow_zero_auth?(credit_card) ? 0 : 100
      end

      def allow_zero_auth?(credit_card)
        # Discover does not support a $0.00 authorization instead use $1.00
        %w(visa master american_express diners_club jcb).include?(credit_card.brand)
      end

      # ==== Customer Profiles
      # :customer_ref_num should be set unless you're happy with Orbital providing one
      #
      # :customer_profile_order_override_ind can be set to map
      # the CustomerRefNum to OrderID or Comments. Defaults to 'NO' - no mapping
      #
      #   'NO' - No mapping to order data
      #   'OI' - Use <CustomerRefNum> for <OrderID>
      #   'OD' - Use <CustomerRefNum> for <Comments>
      #   'OA' - Use <CustomerRefNum> for <OrderID> and <Comments>
      #
      # :order_default_description can be set optionally. 64 char max.
      #
      # :order_default_amount can be set optionally. integer as cents.
      #
      # :status defaults to Active
      #
      #   'A' - Active
      #   'I' - Inactive
      #   'MS'  - Manual Suspend

      def add_customer_profile(credit_card, options = {})
        options[:customer_profile_action] = CREATE
        order = build_customer_request_xml(credit_card, options)
        commit(order, :add_customer_profile)
      end

      def update_customer_profile(credit_card, options = {})
        options[:customer_profile_action] = UPDATE
        order = build_customer_request_xml(credit_card, options)
        commit(order, :update_customer_profile)
      end

      def retrieve_customer_profile(customer_ref_num)
        options = { customer_profile_action: RETRIEVE, customer_ref_num: }
        order = build_customer_request_xml(nil, options)
        commit(order, :retrieve_customer_profile)
      end

      def delete_customer_profile(customer_ref_num)
        options = { customer_profile_action: DELETE, customer_ref_num: }
        order = build_customer_request_xml(nil, options)
        commit(order, :delete_customer_profile)
      end

      def supports_network_tokenization?
        true
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((<OrbitalConnectionUsername>).+(</OrbitalConnectionUsername>)), '\1[FILTERED]\2').
          gsub(%r((<OrbitalConnectionPassword>).+(</OrbitalConnectionPassword>)), '\1[FILTERED]\2').
          gsub(%r((<AccountNum>).+(</AccountNum>)), '\1[FILTERED]\2').
          # the response sometimes contains a new line that cuts off the end of the closing tag
          gsub(%r((<CCAccountNum>).+(</CC)), '\1[FILTERED]\2').
          gsub(%r((<CardSecVal>).+(</CardSecVal>)), '\1[FILTERED]\2').
          gsub(%r((<MerchantID>).+(</MerchantID>)), '\1[FILTERED]\2').
          gsub(%r((<CustomerMerchantID>).+(</CustomerMerchantID>)), '\1[FILTERED]\2').
          gsub(%r((<CustomerProfileMessage>).+(</CustomerProfileMessage>)), '\1[FILTERED]\2').
          gsub(%r((<CheckDDA>).+(</CheckDDA>)), '\1[FILTERED]\2').
          gsub(%r((<BCRtNum>).+(</BCRtNum>)), '\1[FILTERED]\2').
          gsub(%r((<DigitalTokenCryptogram>).+(</DigitalTokenCryptogram>)), '\1[FILTERED]\2')
      end

      private

      def force_capture_with_echeck?(payment_source, options)
        return false unless options[:force_capture]
        return false unless payment_source.is_a?(Check)

        %w(W8 W9 ND).include?(options[:action_code])
      end

      #=====REFERENCE FIELDS=====

      def add_customer_data(xml, credit_card, options)
        add_customer_ref_num(xml, options)

        return if options[:profile_txn]

        xml.tag! :CustomerProfileFromOrderInd, profile_number(options) if add_profile_number?(options, credit_card)
        xml.tag! :CustomerProfileOrderOverrideInd, options[:customer_profile_order_override_ind] || NO_MAPPING_TO_ORDER_DATA
      end

      def add_profile_number?(options, credit_card)
        return true unless options[:customer_ref_num] && credit_card.nil?
      end

      def profile_number(options)
        options[:customer_ref_num] ? USE_CUSTOMER_REF_NUM : AUTO_GENERATE
      end

      def add_customer_ref_num(xml, options)
        xml.tag! :CustomerRefNum, options[:customer_ref_num] if options[:customer_ref_num]
      end

      def add_tx_ref_num(xml, authorization)
        return unless authorization

        xml.tag! :TxRefNum, split_authorization(authorization).first
      end

      def authorization_string(options, response)
        authorization = [response[:tx_ref_num], response[:order_id], response[:safetech_token], response[:card_brand]]
        authorization << options[:exp_date] if options[:exp_date] && options[:token_txn_type] == GET_TOKEN
        authorization.compact.join(';')
      end

      def split_authorization(authorization)
        authorization.split(';')
      end

      #=====DESCRIPTOR FIELDS=====

      def add_soft_descriptors(xml, descriptors)
        return unless descriptors

        add_soft_descriptors_from_specialized_class(xml, descriptors) if descriptors.is_a?(OrbitalSoftDescriptors)
        add_soft_descriptors_from_hash(xml, descriptors) if descriptors.is_a?(Hash)
      end

      def add_payment_action_ind(xml, payment_action_ind)
        return unless payment_action_ind

        xml.tag! :PaymentActionInd, payment_action_ind
      end

      def add_soft_descriptors_from_specialized_class(xml, soft_desc)
        xml.tag! :SDMerchantName, soft_desc.merchant_name             if soft_desc.merchant_name
        xml.tag! :SDProductDescription, soft_desc.product_description if soft_desc.product_description
        xml.tag! :SDMerchantCity, soft_desc.merchant_city             if soft_desc.merchant_city
        xml.tag! :SDMerchantPhone, soft_desc.merchant_phone           if soft_desc.merchant_phone
        xml.tag! :SDMerchantURL, soft_desc.merchant_url               if soft_desc.merchant_url
        xml.tag! :SDMerchantEmail, soft_desc.merchant_email           if soft_desc.merchant_email
      end

      def add_soft_descriptors_from_hash(xml, soft_desc)
        xml.tag! :SDMerchantName, soft_desc[:merchant_name] || nil
        xml.tag! :SDProductDescription, soft_desc[:product_description] || nil
        xml.tag! :SDMerchantCity, soft_desc[:merchant_city] || nil
        xml.tag! :SDMerchantPhone, soft_desc[:merchant_phone] || nil
        xml.tag! :SDMerchantURL, soft_desc[:merchant_url] || nil
        xml.tag! :SDMerchantEmail, soft_desc[:merchant_email] || nil
      end

      def add_level2_tax(xml, options = {})
        if (level2 = options[:level_2_data])
          xml.tag! :TaxInd, level2[:tax_indicator] if [TAX_NOT_PROVIDED, TAX_INCLUDED, NON_TAXABLE_TRANSACTION].include?(level2[:tax_indicator].to_i)
          xml.tag! :Tax, level2[:tax].to_i if level2[:tax]
        end
      end

      def add_level3_tax(xml, options = {})
        if (level3 = options[:level_3_data])
          xml.tag! :PC3VATtaxAmt, byte_limit(level3[:vat_tax], 12) if level3[:vat_tax]
          xml.tag! :PC3VATtaxRate, byte_limit(level3[:vat_rate], 4) if level3[:vat_rate]
          xml.tag! :PC3AltTaxInd, byte_limit(level3[:alt_ind], 15) if level3[:alt_ind]
          xml.tag! :PC3AltTaxAmt, byte_limit(level3[:alt_tax], 9) if level3[:alt_tax]
        end
      end

      def add_level2_advice_addendum(xml, options = {})
        if (level2 = options[:level_2_data])
          xml.tag! :AMEXTranAdvAddn1, byte_limit(level2[:advice_addendum_1], 40) if level2[:advice_addendum_1]
          xml.tag! :AMEXTranAdvAddn2, byte_limit(level2[:advice_addendum_2], 40) if level2[:advice_addendum_2]
          xml.tag! :AMEXTranAdvAddn3, byte_limit(level2[:advice_addendum_3], 40) if level2[:advice_addendum_3]
          xml.tag! :AMEXTranAdvAddn4, byte_limit(level2[:advice_addendum_4], 40) if level2[:advice_addendum_4]
        end
      end

      def add_level2_purchase(xml, options = {})
        if (level2 = options[:level_2_data])
          xml.tag! :PCOrderNum,       byte_limit(level2[:purchase_order], 17) if level2[:purchase_order]
          xml.tag! :PCDestZip,        byte_limit(format_address_field(level2[:zip]), 10) if level2[:zip]
          xml.tag! :PCDestName,       byte_limit(format_address_field(level2[:name]), 30) if level2[:name]
          xml.tag! :PCDestAddress1,   byte_limit(format_address_field(level2[:address1]), 30) if level2[:address1]
          xml.tag! :PCDestAddress2,   byte_limit(format_address_field(level2[:address2]), 30) if level2[:address2]
          xml.tag! :PCDestCity,       byte_limit(format_address_field(level2[:city]), 20) if level2[:city]
          xml.tag! :PCDestState,      byte_limit(format_address_field(level2[:state]), 2) if level2[:state]
        end
      end

      def add_level3_purchase(xml, options = {})
        if (level3 = options[:level_3_data])
          xml.tag! :PC3FreightAmt,    byte_limit(level3[:freight_amount], 12) if level3[:freight_amount]
          xml.tag! :PC3DutyAmt,       byte_limit(level3[:duty_amount], 12) if level3[:duty_amount]
          xml.tag! :PC3DestCountryCd, byte_limit(level3[:dest_country], 3) if level3[:dest_country]
          xml.tag! :PC3ShipFromZip,   byte_limit(level3[:ship_from_zip], 10) if level3[:ship_from_zip]
          xml.tag! :PC3DiscAmt,       byte_limit(level3[:discount_amount], 12) if level3[:discount_amount]
        end
      end

      def add_line_items(xml, options = {})
        xml.tag! :PC3LineItemCount, byte_limit(options[:line_items].count, 2)
        xml.tag! :PC3LineItemArray do
          options[:line_items].each_with_index do |line_item, index|
            xml.tag! :PC3LineItem do
              xml.tag! :PC3DtlIndex,  byte_limit(index + 1, 2)
              line_item.each do |key, value|
                if [:line_tot, 'line_tot'].include? key
                  formatted_key = :PC3Dtllinetot
                else
                  formatted_key = "PC3Dtl#{key.to_s.camelize}".to_sym
                end
                xml.tag! formatted_key, value
              end
            end
          end
        end
      end

      def add_level2_card_and_more_tax(xml, options = {})
        if (level2 = options[:level_2_data])
          xml.tag! :PCardRequestorName, byte_limit(level2[:requestor_name], 38) if level2[:requestor_name]
          xml.tag! :PCardLocalTaxRate, byte_limit(level2[:local_tax_rate], 5) if level2[:local_tax_rate]
          # Canadian Merchants Only
          xml.tag! :PCardNationalTax, byte_limit(level2[:national_tax], 12) if level2[:national_tax]
          xml.tag! :PCardPstTaxRegNumber, byte_limit(level2[:pst_tax_reg_number], 15) if level2[:pst_tax_reg_number]
          xml.tag! :PCardCustomerVatRegNumber, byte_limit(level2[:customer_vat_reg_number], 13) if level2[:customer_vat_reg_number]
          # Canadian Merchants Only
          xml.tag! :PCardMerchantVatRegNumber, byte_limit(level2[:merchant_vat_reg_number], 20) if level2[:merchant_vat_reg_number]
          xml.tag! :PCardTotalTaxAmount, byte_limit(level2[:total_tax_amount], 12) if level2[:total_tax_amount]
        end
      end

      def add_card_commodity_code(xml, options = {})
        if (level2 = options[:level_2_data]) && (level2[:commodity_code])
          xml.tag! :PCardCommodityCode, byte_limit(level2[:commodity_code], 4)
        end
      end

      def add_level3_vat_fields(xml, options = {})
        if (level3 = options[:level_3_data])
          xml.tag! :PC3InvoiceDiscTreatment, byte_limit(level3[:invoice_discount_treatment], 1) if level3[:invoice_discount_treatment]
          xml.tag! :PC3TaxTreatment, byte_limit(level3[:tax_treatment], 1) if level3[:tax_treatment]
          xml.tag! :PC3UniqueVATInvoiceRefNum, byte_limit(level3[:unique_vat_invoice_ref], 15) if level3[:unique_vat_invoice_ref]
          xml.tag! :PC3ShipVATRate, byte_limit(level3[:ship_vat_rate], 4) if level3[:ship_vat_rate]
        end
      end

      #=====ADDRESS FIELDS=====

      def add_address(xml, payment_source, options)
        return unless (address = get_address(options))

        if avs_supported?(address[:country]) || empty?(address[:country])
          xml.tag! :AVSzip, byte_limit(format_address_field(address[:zip]), 10)
          xml.tag! :AVSaddress1, byte_limit(format_address_field(address[:address1]), 30)
          xml.tag! :AVSaddress2, byte_limit(format_address_field(address[:address2]), 30)
          xml.tag! :AVScity, byte_limit(format_address_field(address[:city]), 20)
          xml.tag! :AVSstate, byte_limit(format_address_field(address[:state]), 2)
          xml.tag! :AVSphoneNum, (address[:phone] ? address[:phone].scan(/\d/).join.to_s[0..13] : nil)
        end

        xml.tag! :AVSname, billing_name(payment_source, options)
        xml.tag! :AVScountryCode, byte_limit(format_address_field(filter_unsupported_countries(address[:country])), 2)

        # Needs to come after AVScountryCode
        add_destination_address(xml, address) if avs_supported?(address[:country]) || empty?(address[:country])
      end

      def add_destination_address(xml, address)
        return unless address[:dest_zip]

        xml.tag! :AVSDestzip,         byte_limit(format_address_field(address[:dest_zip]), 10)
        xml.tag! :AVSDestaddress1,    byte_limit(format_address_field(address[:dest_address1]), 30)
        xml.tag! :AVSDestaddress2,    byte_limit(format_address_field(address[:dest_address2]), 30)
        xml.tag! :AVSDestcity,        byte_limit(format_address_field(address[:dest_city]), 20)
        xml.tag! :AVSDeststate,       byte_limit(format_address_field(address[:dest_state]), 2)
        xml.tag! :AVSDestphoneNum,    (address[:dest_phone] ? address[:dest_phone].scan(/\d/).join.to_s[0..13] : nil)
        xml.tag! :AVSDestname,        byte_limit(address[:dest_name], 30)
        xml.tag! :AVSDestcountryCode, filter_unsupported_countries(address[:dest_country])
      end

      # For Profile requests
      def add_customer_address(xml, options)
        return unless (address = get_address(options))

        xml.tag! :CustomerAddress1, byte_limit(format_address_field(address[:address1]), 30)
        xml.tag! :CustomerAddress2, byte_limit(format_address_field(address[:address2]), 30)
        xml.tag! :CustomerCity, byte_limit(format_address_field(address[:city]), 20)
        xml.tag! :CustomerState, byte_limit(format_address_field(address[:state]), 2)
        xml.tag! :CustomerZIP, byte_limit(format_address_field(address[:zip]), 10)
        xml.tag! :CustomerEmail, byte_limit(address[:email], 50) if address[:email]
        xml.tag! :CustomerPhone, (address[:phone] ? address[:phone].scan(/\d/).join.to_s : nil)
        xml.tag! :CustomerCountryCode, filter_unsupported_countries(address[:country])
      end

      def billing_name(payment_source, options)
        name =
          if !payment_source.is_a?(String) && payment_source&.name.present?
            payment_source.name
          elsif options[:billing_address] && options[:billing_address][:name].present?
            options[:billing_address][:name]
          end
        name ? format_name(name)[0..29] : nil
      end

      def avs_supported?(address)
        AVS_SUPPORTED_COUNTRIES.include?(address.to_s)
      end

      def filter_unsupported_countries(address)
        avs_supported?(address) ? address.to_s : ''
      end

      def get_address(options)
        options[:billing_address] || options[:address]
      end

      def add_safetech_token_data(xml, payment_source, options)
        _, _, payment_source_token, card_brand, exp_date = split_authorization(payment_source)
        xml.tag! :CardBrand, card_brand
        xml.tag! :AccountNum, payment_source_token
        xml.tag! :Exp, exp_date if exp_date && options[:pass_exp_date]&.to_s == 'true'
      end

      #=====PAYMENT SOURCE FIELDS=====

      # Payment can be done through either Credit Card or Electronic Check
      def add_payment_source(xml, payment_source, options = {})
        add_safetech_token_data(xml, payment_source, options) if payment_source.is_a?(String)
        payment_source.is_a?(Check) ? add_echeck(xml, payment_source, options) : add_credit_card(xml, payment_source, options)
      end

      def add_echeck(xml, check, options = {})
        return unless check

        xml.tag! :CardBrand, 'EC'
        add_currency_fields(xml, options[:currency])
        xml.tag! :BCRtNum, check.routing_number
        xml.tag! :CheckDDA, check.account_number if check.account_number
        add_bank_account_type(xml, check)
        xml.tag! :ECPAuthMethod, options[:auth_method] if options[:auth_method]
        xml.tag! :BankPmtDelv, options[:payment_delivery] || 'B'
        xml.tag! :AVSname, (check&.name ? format_name(check.name)[0..29] : nil) if get_address(options).blank?
      end

      def add_credit_card(xml, credit_card, options)
        xml.tag! :AccountNum, credit_card.number if credit_card.is_a?(CreditCard)
        xml.tag! :Exp, options[:override_exp_date] || expiry_date(credit_card) if credit_card.is_a?(CreditCard)
        add_currency_fields(xml, options[:currency])
        add_verification_value(xml, credit_card) if credit_card.is_a?(CreditCard)
      end

      def add_verification_value(xml, credit_card)
        return unless credit_card&.verification_value?

        # If you are trying to collect a Card Verification Number
        # (CardSecVal) for a Visa or Discover transaction, pass one of these values:
        #   1 Value is Present
        #   2 Value on card but illegible
        #   9 Cardholder states data not available
        # If the transaction is not a Visa or Discover transaction:
        #   Null-fill this attribute OR
        #   Do not submit the attribute at all.
        # - http://download.chasepaymentech.com/docs/orbital/orbital_gateway_xml_specification.pdf
        xml.tag! :CardSecValInd, '1' if %w(visa discover diners_club).include?(credit_card.brand)
        xml.tag! :CardSecVal, credit_card.verification_value
      end

      def add_currency_fields(xml, currency)
        xml.tag! :CurrencyCode, currency_code(currency)
        xml.tag! :CurrencyExponent, currency_exponents(currency)
      end

      def add_bank_account_type(xml, check)
        bank_account_type =
          if check.account_holder_type == 'business'
            'X'
          else
            ACCOUNT_TYPE[check.account_type]
          end

        xml.tag! :BankAccountType, bank_account_type if bank_account_type
      end

      def add_card_indicators(xml, options)
        xml.tag! :CardIndicators, options[:card_indicators] if options[:card_indicators]
      end

      def currency_code(currency)
        CURRENCY_CODES[(currency || self.default_currency)].to_s
      end

      def currency_exponents(currency)
        CURRENCY_EXPONENTS[(currency || self.default_currency)].to_s
      end

      def expiry_date(credit_card)
        "#{format(credit_card.month, :two_digits)}#{format(credit_card.year, :two_digits)}"
      end

      def bin
        @options[:bin] || (salem_mid? ? '000001' : '000002')
      end

      def salem_mid?
        @options[:merchant_id].length == 6
      end

      #=====BRAND-SPECIFIC FIELDS=====

      def add_cavv(xml, credit_card, three_d_secure)
        return unless three_d_secure && credit_card.brand == 'visa'

        xml.tag!(:CAVV, three_d_secure[:cavv])
      end

      def add_aav(xml, credit_card, three_d_secure)
        return unless three_d_secure && credit_card.brand == 'master'

        xml.tag!(:AAV, three_d_secure[:cavv])
      end

      def add_aevv(xml, credit_card, three_d_secure)
        return unless three_d_secure && credit_card.brand == 'american_express'

        xml.tag!(:AEVV, three_d_secure[:cavv])
      end

      def add_xid(xml, credit_card, three_d_secure)
        return unless three_d_secure && credit_card.brand == 'visa'

        xml.tag!(:XID, three_d_secure[:xid]) if three_d_secure[:xid]
      end

      PYMT_PROGRAM_CODE_BY_BRAND = {
        'american_express' => 'ASK',
        'discover' => 'DPB'
      }.freeze
      def add_pymt_brand_program_code(xml, credit_card, three_d_secure)
        return unless three_d_secure && (code = PYMT_PROGRAM_CODE_BY_BRAND[credit_card.brand])

        xml.tag!(:PymtBrandProgramCode, code)
      end

      def mastercard?(payment_source)
        payment_source.is_a?(CreditCard) && payment_source.brand == 'master'
      end

      def add_mastercard_fields(xml, credit_card, parameters, three_d_secure)
        add_mc_sca_merchant_initiated(xml, credit_card, parameters, three_d_secure)
        add_mc_sca_recurring(xml, credit_card, parameters, three_d_secure)
        add_mc_program_protocol(xml, credit_card, three_d_secure)
        add_mc_directory_trans_id(xml, credit_card, three_d_secure)
        add_mc_ucafind(xml, credit_card, three_d_secure, parameters)
      end

      def add_mc_sca_merchant_initiated(xml, credit_card, parameters, three_d_secure)
        return unless parameters.try(:[], :sca_merchant_initiated)
        return unless three_d_secure.try(:[], :eci) == '7'

        xml.tag!(:SCAMerchantInitiatedTransaction, parameters[:sca_merchant_initiated])
      end

      def add_mc_sca_recurring(xml, credit_card, parameters, three_d_secure)
        return unless parameters.try(:[], :sca_recurring)
        return unless three_d_secure.try(:[], :eci) == '7'

        xml.tag!(:SCARecurringPayment, parameters[:sca_recurring])
      end

      def add_mc_program_protocol(xml, credit_card, three_d_secure)
        return unless version = three_d_secure.try(:[], :version)

        xml.tag!(:MCProgramProtocol, version.to_s[0])
      end

      def add_mc_directory_trans_id(xml, credit_card, three_d_secure)
        return unless three_d_secure

        xml.tag!(:MCDirectoryTransID, three_d_secure[:ds_transaction_id]) if three_d_secure[:ds_transaction_id]
      end

      def add_mc_ucafind(xml, credit_card, three_d_secure, options)
        return unless three_d_secure && %w(4 6 7).include?(three_d_secure&.dig(:eci))

        xml.tag! :UCAFInd, options[:ucaf_collection_indicator] if options[:ucaf_collection_indicator]
      end

      #=====SCA (STORED CREDENTIAL) FIELDS=====

      def add_stored_credentials(xml, parameters)
        return unless parameters[:mit_stored_credential_ind] == 'Y' || (parameters[:stored_credential] && !parameters[:stored_credential].values.all?(&:nil?))

        if msg_type = get_msg_type(parameters)
          xml.tag! :MITMsgType, msg_type
        end
        xml.tag! :MITStoredCredentialInd, 'Y'
        if parameters[:mit_submitted_transaction_id]
          xml.tag! :MITSubmittedTransactionID, parameters[:mit_submitted_transaction_id]
        elsif parameters.dig(:stored_credential, :network_transaction_id) && parameters.dig(:stored_credential, :initiator) == 'merchant'
          xml.tag! :MITSubmittedTransactionID, parameters[:stored_credential][:network_transaction_id]
        end
      end

      def get_msg_type(parameters)
        return parameters[:mit_msg_type] if parameters[:mit_msg_type]
        return 'CSTO' if parameters[:stored_credential][:initial_transaction]
        return unless parameters[:stored_credential][:initiator] && parameters[:stored_credential][:reason_type]

        initiator =
          case parameters[:stored_credential][:initiator]
          when 'cardholder', 'customer' then 'C'
          when 'merchant' then 'M'
          end
        reason =
          case parameters[:stored_credential][:reason_type]
          when 'recurring' then 'REC'
          when 'installment' then 'INS'
          when 'unscheduled' then 'USE'
          end

        "#{initiator}#{reason}"
      end

      #=====NETWORK TOKENIZATION FIELDS=====

      def add_eci(xml, credit_card, three_d_secure)
        eci = if three_d_secure
                three_d_secure[:eci]
              elsif credit_card.is_a?(NetworkTokenizationCreditCard)
                credit_card.eci
              end

        xml.tag!(:AuthenticationECIInd, eci) if eci
      end

      def add_dpanind(xml, credit_card, industry_type = nil)
        return unless credit_card.is_a?(NetworkTokenizationCreditCard)

        xml.tag! :DPANInd, 'Y' unless industry_type == 'RC'
      end

      def add_digital_token_cryptogram(xml, credit_card, three_d_secure)
        return unless credit_card.is_a?(NetworkTokenizationCreditCard) || (three_d_secure && credit_card.brand == 'discover')

        cryptogram =
          if three_d_secure && credit_card.brand == 'discover'
            three_d_secure[:cavv]
          else
            credit_card.payment_cryptogram
          end

        xml.tag!(:DigitalTokenCryptogram, cryptogram)
      end

      #=====OTHER FIELDS=====

      # For Canadian transactions on PNS Tampa on New Order
      # RF - First Recurring Transaction
      # RS - Subsequent Recurring Transactions
      def set_recurring_ind(xml, parameters)
        return unless parameters[:recurring_ind]
        raise 'RecurringInd must be set to either "RF" or "RS"' unless %w(RF RS).include?(parameters[:recurring_ind])

        xml.tag! :RecurringInd, parameters[:recurring_ind]
      end

      def add_managed_billing(xml, options)
        return unless mb = options[:managed_billing]

        ActiveMerchant.deprecated RECURRING_DEPRECATION_MESSAGE

        # default to recurring (R).  Other option is deferred (D).
        xml.tag! :MBType, mb[:type] || RECURRING
        # default to Customer Reference Number
        xml.tag! :MBOrderIdGenerationMethod,     mb[:order_id_generation_method] || 'IO'
        # By default use MBRecurringEndDate, set to N.
        # MMDDYYYY
        xml.tag! :MBRecurringStartDate,          mb[:start_date].scan(/\d/).join.to_s if mb[:start_date]
        # MMDDYYYY
        xml.tag! :MBRecurringEndDate,            mb[:end_date].scan(/\d/).join.to_s if mb[:end_date]
        # By default listen to any value set in MBRecurringEndDate.
        xml.tag! :MBRecurringNoEndDateFlag,      mb[:no_end_date_flag] || 'N' # 'Y' || 'N' (Yes or No).
        xml.tag! :MBRecurringMaxBillings,        mb[:max_billings]       if mb[:max_billings]
        xml.tag! :MBRecurringFrequency,          mb[:frequency]          if mb[:frequency]
        xml.tag! :MBDeferredBillDate,            mb[:deferred_bill_date] if mb[:deferred_bill_date]
        xml.tag! :MBMicroPaymentMaxDollarValue,  mb[:max_dollar_value]   if mb[:max_dollar_value]
        xml.tag! :MBMicroPaymentMaxBillingDays,  mb[:max_billing_days]   if mb[:max_billing_days]
        xml.tag! :MBMicroPaymentMaxTransactions, mb[:max_transactions]   if mb[:max_transactions]
      end

      def add_ews_details(xml, payment_source, parameters = {})
        split_name = payment_source.first_name.split if payment_source.first_name
        xml.tag! :EWSFirstName, split_name[0]
        xml.tag! :EWSMiddleName, split_name[1..-1].join(' ')
        xml.tag! :EWSLastName, payment_source.last_name
        xml.tag! :EWSBusinessName, parameters[:company] if payment_source.first_name.empty? && payment_source.last_name.empty?

        if (address = (parameters[:billing_address] || parameters[:address]))
          xml.tag! :EWSAddressLine1, byte_limit(format_address_field(address[:address1]), 30)
          xml.tag! :EWSAddressLine2, byte_limit(format_address_field(address[:address2]), 30)
          xml.tag! :EWSCity, byte_limit(format_address_field(address[:city]), 20)
          xml.tag! :EWSState, byte_limit(format_address_field(address[:state]), 2)
          xml.tag! :EWSZip, byte_limit(format_address_field(address[:zip]), 10)
        end

        xml.tag! :EWSPhoneType, parameters[:phone_type]
        xml.tag! :EWSPhoneNumber, parameters[:phone_number]
        xml.tag! :EWSCheckSerialNumber, payment_source.account_number unless parameters[:auth_method].eql?('I')
      end

      # Adds ECP conditional attributes depending on other attribute values
      def add_ecp_details(xml, payment_source, parameters = {})
        requires!(payment_source.account_number) if parameters[:auth_method]&.eql?('A') || parameters[:auth_method]&.eql?('P')
        xml.tag! :ECPActionCode, parameters[:action_code] if parameters[:action_code]
        xml.tag! :ECPCheckSerialNumber, payment_source.account_number if parameters[:auth_method]&.eql?('A') || parameters[:auth_method]&.eql?('P')
        if parameters[:auth_method]&.eql?('P')
          xml.tag! :ECPTerminalCity, parameters[:terminal_city] if parameters[:terminal_city]
          xml.tag! :ECPTerminalState, parameters[:terminal_state] if parameters[:terminal_state]
          xml.tag! :ECPImageReferenceNumber, parameters[:image_reference_number] if parameters[:image_reference_number]
        end
        if parameters[:action_code]&.eql?('W3') || parameters[:action_code]&.eql?('W5') ||
           parameters[:action_code]&.eql?('W7') || parameters[:action_code]&.eql?('W9')
          add_ews_details(xml, payment_source, parameters)
        end
      end

      def add_xml_credentials(xml)
        unless ip_authentication?
          xml.tag! :OrbitalConnectionUsername, @options[:login]
          xml.tag! :OrbitalConnectionPassword, @options[:password]
        end
      end

      def add_bin_merchant_and_terminal(xml, parameters)
        xml.tag! :BIN, bin
        xml.tag! :MerchantID, @options[:merchant_id]
        xml.tag! :TerminalID, parameters[:terminal_id] || '001'
      end

      #=====REQUEST/RESPONSE METHODS=====

      def commit(order, message_type, options = {})
        headers = POST_HEADERS.merge('Content-length' => order.size.to_s)
        if (@options[:retry_logic] || options[:retry_logic]) && options[:trace_number]
          headers['Trace-number'] = options[:trace_number].to_s
          headers['Merchant-Id'] = @options[:merchant_id]
        end
        request = ->(url) { parse(ssl_post(url, order, headers)) }

        # Failover URL will be attempted in the event of a connection error
        response =
          begin
            raise ConnectionError.new 'Should use secondary url', 500 if @use_secondary_url

            request.call(remote_url)
          rescue ConnectionError
            request.call(remote_url(:secondary))
          end

        Response.new(
          success?(response, message_type),
          message_from(response),
          response,
          {
            authorization: authorization_string(options, response),
            test: self.test?,
            avs_result: OrbitalGateway::AVSResult.new(response[:avs_resp_code]),
            cvv_result: OrbitalGateway::CVVResult.new(response[:cvv2_resp_code])
          }
        )
      end

      def remote_url(url = :primary)
        if url == :primary
          (self.test? ? self.test_url : self.live_url)
        else
          (self.test? ? self.secondary_test_url : self.secondary_live_url)
        end
      end

      def parse(body)
        response = {}
        xml = REXML::Document.new(strip_invalid_xml_chars(body))
        root = REXML::XPath.first(xml, '//Response') ||
               REXML::XPath.first(xml, '//ErrorResponse')
        if root
          root.elements.to_a.each do |node|
            recurring_parse_element(response, node)
          end
        end

        response.delete_if { |k, _| SENSITIVE_FIELDS.include?(k) }
      end

      def recurring_parse_element(response, node)
        if node.has_elements?
          node.elements.each { |e| recurring_parse_element(response, e) }
        else
          response[node.name.underscore.to_sym] = node.text
        end
      end

      def success?(response, message_type)
        if %i[void].include?(message_type)
          response[:proc_status] == SUCCESS
        elsif %i[refund].include?(message_type)
          response[:proc_status] == SUCCESS && response[:approval_status] == APPROVAL_SUCCESS
        elsif response[:customer_profile_action]
          response[:profile_proc_status] == SUCCESS
        else
          response[:proc_status] == SUCCESS &&
            APPROVED.include?(response[:resp_code])
        end
      end

      def message_from(response)
        response[:resp_msg] || response[:status_msg] || response[:customer_profile_message]
      end

      def ip_authentication?
        @options[:ip_authentication] == true
      end

      #=====BUILDER METHODS=====

      def build_new_auth_purchase_order(action, money, payment_source, options)
        build_new_order_xml(action, money, payment_source, options) do |xml|
          add_payment_source(xml, payment_source, options)
          add_address(xml, payment_source, options)
          if @options[:customer_profiles]
            add_customer_data(xml, payment_source, options)
            add_managed_billing(xml, options)
          end
        end
      end

      def build_new_order_xml(action, money, payment_source, parameters = {})
        requires!(parameters, :order_id)
        @use_secondary_url = parameters[:use_secondary_url] if parameters[:use_secondary_url]
        xml = xml_envelope
        xml.tag! :Request do
          xml.tag! :NewOrder do
            add_xml_credentials(xml)
            xml.tag! :IndustryType, parameters[:industry_type] || ECOMMERCE_TRANSACTION
            xml.tag! :MessageType, action
            add_bin_merchant_and_terminal(xml, parameters)

            yield xml if block_given?

            three_d_secure = parameters[:three_d_secure]

            add_eci(xml, payment_source, three_d_secure)
            add_cavv(xml, payment_source, three_d_secure)
            add_xid(xml, payment_source, three_d_secure)

            xml.tag! :OrderID, format_order_id(parameters[:order_id])
            xml.tag! :Amount, amount(money)
            xml.tag! :Comments, parameters[:comments] if parameters[:comments]
            add_level2_tax(xml, parameters)
            add_level2_advice_addendum(xml, parameters)
            add_aav(xml, payment_source, three_d_secure)
            # CustomerAni, AVSPhoneType and AVSDestPhoneType could be added here.
            add_soft_descriptors(xml, parameters[:soft_descriptors])
            set_recurring_ind(xml, parameters)

            # Append Transaction Reference Number at the end for Refund transactions
            add_tx_ref_num(xml, parameters[:authorization]) if action == REFUND && payment_source.nil?
            add_level2_purchase(xml, parameters)
            add_level3_purchase(xml, parameters)
            add_level3_tax(xml, parameters)
            add_line_items(xml, parameters) if parameters[:line_items]
            add_card_indicators(xml, parameters)
            add_payment_action_ind(xml, parameters[:payment_action_ind])
            add_dpanind(xml, payment_source, parameters[:industry_type])
            add_aevv(xml, payment_source, three_d_secure)
            add_level2_card_and_more_tax(xml, parameters)
            add_digital_token_cryptogram(xml, payment_source, three_d_secure)
            xml.tag! :ECPSameDayInd, parameters[:same_day] if parameters[:same_day] && payment_source.is_a?(Check)
            add_ecp_details(xml, payment_source, parameters) if payment_source.is_a?(Check)

            add_stored_credentials(xml, parameters)
            add_pymt_brand_program_code(xml, payment_source, three_d_secure)
            xml.tag! :TokenTxnType, parameters[:token_txn_type] if parameters[:token_txn_type]
            add_mastercard_fields(xml, payment_source, parameters, three_d_secure) if mastercard?(payment_source)
            add_card_commodity_code(xml, parameters)
            add_level3_vat_fields(xml, parameters)
          end
        end
        xml.target!
      end

      def build_mark_for_capture_xml(money, authorization, parameters = {})
        tx_ref_num, order_id = split_authorization(authorization)
        xml = xml_envelope
        xml.tag! :Request do
          xml.tag! :MarkForCapture do
            add_xml_credentials(xml)
            xml.tag! :OrderID, format_order_id(order_id)
            xml.tag! :Amount, amount(money)
            add_level2_tax(xml, parameters)
            add_bin_merchant_and_terminal(xml, parameters)
            xml.tag! :TxRefNum, tx_ref_num
            add_level2_purchase(xml, parameters)
            add_level2_advice_addendum(xml, parameters)
            add_level3_purchase(xml, parameters)
            add_level3_tax(xml, parameters)
            add_line_items(xml, parameters) if parameters[:line_items]
            add_level2_card_and_more_tax(xml, parameters)
            add_card_commodity_code(xml, parameters)
            add_level3_vat_fields(xml, parameters)
          end
        end
        xml.target!
      end

      def build_void_request_xml(authorization, parameters = {})
        tx_ref_num, order_id = split_authorization(authorization)
        xml = xml_envelope
        xml.tag! :Request do
          xml.tag! :Reversal do
            add_xml_credentials(xml)
            xml.tag! :TxRefNum, tx_ref_num
            xml.tag! :TxRefIdx, parameters[:transaction_index]
            xml.tag! :AdjustedAmt, parameters[:amount] # setting adjusted amount to nil will void entire amount
            xml.tag! :OrderID, format_order_id(order_id || parameters[:order_id])
            add_bin_merchant_and_terminal(xml, parameters)
            xml.tag! :ReversalRetryNumber, parameters[:reversal_retry_number] if parameters[:reversal_retry_number]
            xml.tag! :OnlineReversalInd,   parameters[:online_reversal_ind]   if parameters[:online_reversal_ind]
          end
        end
        xml.target!
      end

      def xml_envelope
        xml = Builder::XmlMarkup.new(indent: 2)
        xml.instruct!(:xml, version: '1.0', encoding: 'UTF-8')
        xml
      end

      # Null characters are possible in some responses (namely, the respMsg field), causing XML parsing errors
      # Prevent by substituting these with a valid placeholder string
      def strip_invalid_xml_chars(xml)
        xml.gsub(/\u0000/, '[null]')
      end

      # The valid characters include:
      #
      # 1. all letters and digits
      # 2. - , $ @ & and a space character, though the space character cannot be the leading character
      # 3. PINless Debit transactions can only use uppercase and lowercase alpha (A-Z, a-z) and numeric (0-9)
      def format_order_id(order_id)
        illegal_characters = /[^,$@&\- \w]/
        order_id = order_id.to_s.tr('.', '-')
        order_id.gsub!(illegal_characters, '')
        order_id.lstrip!
        order_id[0...22]
      end

      # Address-related fields cannot contain % | ^ \ /
      # Returns the value with these characters removed, or nil
      def format_address_field(value)
        value.gsub(/[%\|\^\\\/]/, '') if value.respond_to?(:gsub)
      end

      # Field lengths should be limited by byte count instead of character count
      # Returns the truncated value or nil
      def byte_limit(value, byte_length)
        limited_value = ''

        value.to_s.each_char do |c|
          break if (limited_value.bytesize + c.bytesize) > byte_length

          limited_value << c
        end

        limited_value
      end

      def build_customer_request_xml(credit_card, options = {})
        ActiveMerchant.deprecated 'Customer Profile support in Orbital is non-conformant to the ActiveMerchant API and will be removed in its current form in a future version. Please contact the ActiveMerchant maintainers if you have an interest in modifying it to conform to the store/unstore/update API.'
        xml = xml_envelope
        xml.tag! :Request do
          xml.tag! :Profile do
            xml.tag! :OrbitalConnectionUsername, @options[:login] unless ip_authentication?
            xml.tag! :OrbitalConnectionPassword, @options[:password] unless ip_authentication?
            xml.tag! :CustomerBin, bin
            xml.tag! :CustomerMerchantID, @options[:merchant_id]
            xml.tag! :CustomerName, credit_card.name if credit_card
            xml.tag! :CustomerRefNum, options[:customer_ref_num] if options[:customer_ref_num]

            add_customer_address(xml, options)

            xml.tag! :CustomerProfileAction, options[:customer_profile_action] # C, R, U, D
            # NO No mapping to order data
            # OI Use <CustomerRefNum> for <OrderID>
            # OD Use <CustomerReferNum> for <Comments>
            # OA Use <CustomerRefNum> for <OrderID> and <Comments>
            xml.tag! :CustomerProfileOrderOverrideInd, options[:customer_profile_order_override_ind] || NO_MAPPING_TO_ORDER_DATA

            if options[:customer_profile_action] == CREATE
              # A Auto-Generate the CustomerRefNum
              # S Use CustomerRefNum field
              # O Use OrderID field
              # D Use Comments field
              xml.tag! :CustomerProfileFromOrderInd, (options[:customer_ref_num] ? USE_CUSTOMER_REF_NUM : AUTO_GENERATE)
            end

            xml.tag! :OrderDefaultDescription, options[:order_default_description][0..63] if options[:order_default_description]
            xml.tag! :OrderDefaultAmount, options[:order_default_amount] if options[:order_default_amount]

            if [CREATE, UPDATE].include? options[:customer_profile_action]
              xml.tag! :CustomerAccountType, 'CC' # Only credit card supported
              xml.tag! :Status, options[:status] || ACTIVE # Active
            end

            xml.tag! :CCAccountNum, credit_card.number if credit_card
            xml.tag! :CCExpireDate, credit_card.expiry_date.expiration.strftime('%m%y') if credit_card

            # This has to come after CCExpireDate.
            add_managed_billing(xml, options)
          end
        end
        xml.target!
      end

      # Unfortunately, Orbital uses their own special codes for AVS responses
      # that are different than the standard codes defined in
      # <tt>ActiveMerchant::Billing::AVSResult</tt>.
      #
      # This class encapsulates the response codes shown on page 240 of their spec:
      # http://download.chasepaymentech.com/docs/orbital/orbital_gateway_xml_specification.pdf
      #
      class AVSResult < ActiveMerchant::Billing::AVSResult
        CODES = {
          '1'  => 'No address supplied',
          '2'  => 'Bill-to address did not pass Auth Host edit checks',
          '3'  => 'AVS not performed',
          '4'  => 'Issuer does not participate in AVS',
          '5'  => 'Edit-error - AVS data is invalid',
          '6'  => 'System unavailable or time-out',
          '7'  => 'Address information unavailable',
          '8'  => 'Transaction Ineligible for AVS',
          '9'  => 'Zip Match/Zip 4 Match/Locale match',
          'A'  => 'Zip Match/Zip 4 Match/Locale no match',
          'B'  => 'Zip Match/Zip 4 no Match/Locale match',
          'C'  => 'Zip Match/Zip 4 no Match/Locale no match',
          'D'  => 'Zip No Match/Zip 4 Match/Locale match',
          'E'  => 'Zip No Match/Zip 4 Match/Locale no match',
          'F'  => 'Zip No Match/Zip 4 No Match/Locale match',
          'G'  => 'No match at all',
          'H'  => 'Zip Match/Locale match',
          'J'  => 'Issuer does not participate in Global AVS',
          'JA' => 'International street address and postal match',
          'JB' => 'International street address match. Postal code not verified',
          'JC' => 'International street address and postal code not verified',
          'JD' => 'International postal code match. Street address not verified',
          'M1' => 'Cardholder name matches',
          'M2' => 'Cardholder name, billing address, and postal code matches',
          'M3' => 'Cardholder name and billing code matches',
          'M4' => 'Cardholder name and billing address match',
          'M5' => 'Cardholder name incorrect, billing address and postal code match',
          'M6' => 'Cardholder name incorrect, billing postal code matches',
          'M7' => 'Cardholder name incorrect, billing address matches',
          'M8' => 'Cardholder name, billing address and postal code are all incorrect',
          'N3' => 'Address matches, ZIP not verified',
          'N4' => 'Address and ZIP code not verified due to incompatible formats',
          'N5' => 'Address and ZIP code match (International only)',
          'N6' => 'Address not verified (International only)',
          'N7' => 'ZIP matches, address not verified',
          'N8' => 'Address and ZIP code match (International only)',
          'N9' => 'Address and ZIP code match (UK only)',
          'R'  => 'Issuer does not participate in AVS',
          'UK' => 'Unknown',
          'X'  => 'Zip Match/Zip 4 Match/Address Match',
          'Z'  => 'Zip Match/Locale no match'
        }

        # Map vendor's AVS result code to a postal match code
        ORBITAL_POSTAL_MATCH_CODE = {
          'Y' => %w(9 A B C H JA JD M2 M3 M5 N5 N8 N9 X Z),
          'N' => %w(D E F G M8),
          'X' => %w(4 J R),
          nil => %w(1 2 3 5 6 7 8 JB JC M1 M4 M6 M7 N3 N4 N6 N7 UK)
        }.inject({}) do |map, (type, codes)|
          codes.each { |code| map[code] = type }
          map
        end

        # Map vendor's AVS result code to a street match code
        ORBITAL_STREET_MATCH_CODE = {
          'Y' => %w(9 B D F H JA JB M2 M4 M5 M6 M7 N3 N5 N7 N8 N9 X),
          'N' => %w(A C E G M8 Z),
          'X' => %w(4 J R),
          nil => %w(1 2 3 5 6 7 8 JC JD M1 M3 N4 N6 UK)
        }.inject({}) do |map, (type, codes)|
          codes.each { |code| map[code] = type }
          map
        end

        def self.messages
          CODES
        end

        def initialize(code)
          @code = (code.blank? ? nil : code.to_s.strip.upcase)
          if @code
            @message      = CODES[@code]
            @postal_match = ORBITAL_POSTAL_MATCH_CODE[@code]
            @street_match = ORBITAL_STREET_MATCH_CODE[@code]
          end
        end
      end

      # Unfortunately, Orbital uses their own special codes for CVV responses
      # that are different than the standard codes defined in
      # <tt>ActiveMerchant::Billing::CVVResult</tt>.
      #
      # This class encapsulates the response codes shown on page 255 of their spec:
      # http://download.chasepaymentech.com/docs/orbital/orbital_gateway_xml_specification.pdf
      #
      class CVVResult < ActiveMerchant::Billing::CVVResult
        MESSAGES = {
          'M' => 'Match',
          'N' => 'No match',
          'P' => 'Not processed',
          'S' => 'Should have been present',
          'U' => 'Unsupported by issuer/Issuer unable to process request',
          'I' => 'Invalid',
          'Y' => 'Invalid',
          ''  => 'Not applicable'
        }

        def self.messages
          MESSAGES
        end

        def initialize(code)
          @code = code.blank? ? '' : code.upcase
          @message = MESSAGES[@code]
        end
      end
    end
  end
end
