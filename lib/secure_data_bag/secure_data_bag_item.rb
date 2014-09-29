
require 'open-uri'
require 'chef/data_bag_item'
require 'chef/encrypted_data_bag_item/encryptor'
require 'chef/encrypted_data_bag_item/decryptor'

module SecureDataBag
  #
  # SecureDataBagItem extends the standard DataBagItem by providing it
  # with encryption / decryption capabilities.
  #
  # Although it does provide methods which may be used to specifically perform
  # crypto functions, it should be used the same way.
  #

  class Item < Chef::DataBagItem
    def initialize(key=nil, fields:nil, secret:nil, data:nil)
      super()

      @secret = Chef::Config[:encrypted_data_bag_secret]
      @key = key

      @raw_data = {}
      unless data.nil?
        self.raw_data = data
      end
      
      @encoded_fields = Chef::Config[:secure_data_bag_fields] || ["password"]
      unless fields.nil?
        encoded_fields(fields)
      end
    end

    #
    # Methods for encryption key
    #

    def secret(arg=nil)
      set_or_return(:secret, arg, kind_of: String)
    end

    def key(arg=nil)
      @key = arg unless arg.nil?
      @key ||= load_key
    end

    def load_key
      @key = self.class.load_secret(secret)
    end

    def self.load_secret(path=nil)
      path ||= Chef::Config[:encrypted_data_bag_secret]

      unless path
       raise ArgumentError, "No secret specified and no secret found."
      end

      key = case path
            when /^\w+:\/\// # Remove key
              begin
                Kernel.open(path).read.strip
              rescue Errno::ECONNREFUSED
                raise ArgumentError, "Remove key not available from '#{path}'"
              rescue OpenURI::HTTPError
                raise ArgumentError, "Remove key not found at '#{path}'"
              end
            else
              unless File.exist?(path)
                raise Errno::ENOENT, "file not found '#{path}'"
              end
              IO.read(path).strip
            end

      if key.size < 1
        raise ArgumentError, "invalid zero length path in '#{path}'"
      end

      key
    end

    def self.load(data_bag, name, key:nil, fields:nil, secret:nil)
      data = super
      new(key, fields, secret, data)
    end

    #
    # Setter for @raw_data
    # - ensure the data we receive is a Mash to support symbols
    # - pass it to DataBagItem for additional validation
    # - ensure the data has the encryption hash
    # - decode the data
    #

    def raw_data=(data)
      data = Mash.new(data)
      super data
      decode_data!
    end

    #
    # Fields we wish to encode
    #

    def encoded_fields(arg=nil)
      arg = arg.uniq if arg.is_a?(Array)
      set_or_return(:encode_fields, arg, kind_of: Array).uniq
    end

    #
    # Raw Data decoder methods
    #

    def decode_data!
      @raw_data = decoded_data
      @raw_data
    end

    def decoded_data
      if encoded_value?(@raw_data) then decode_value(@raw_data)
      else decode_hash(@raw_data)
      end
    end

    def decode_hash(hash)
      hash.each do |k,v|
        v = if encoded_value?(v) then decode_value(v)
            elsif v.is_a?(Hash) then decode_hash(v)
            else v
            end
        hash[k] = v
      end
      hash
    end

    def decode_value(value)
      Chef::EncryptedDataBagItem::Decryptor.for(value, key).for_decrypted_item
    end

    def encoded_value?(value)
      value.is_a?(Hash) and value.key?(:encrypted_data)
    end

    #
    # Raw Data encoded methods
    #

    def encode_data!
      @raw_data = encoded_data
      @raw_data
    end

    def encoded_data
      encode_hash(@raw_data.dup)
    end

    def encode_hash(hash)
      hash.each do |k,v|
        v = if encoded_fields.include?(k) then encode_value(v)
            else encode_hash(v)
            end
        hash[k] = v
      end
      hash
    end

    def encode_value(value)
      Chef::EncryptedDataBagItem::Encryptor.new(value, key).for_encrypted_item
    end

    #
    # Transitions
    #

    def self.from_hash(h, key:nil, fields:nil, secret:nil)
      item = new(key, key, fields, secret)
      item.raw_data = h
      item
    end

    def self.from_item(h, key:nil, fields:nil, secret:nil)
      item = self.from_hash(h.to_hash, key, fields, secret)
      item.data_bag h.data_bag
      item
    end

    def to_hash(encoded: true)
      result = encoded ? encoded_data : @raw_data
      result["chef_type"] = "data_bag_item"
      result["data_bag"] = self.data_bag
      result
    end

    def to_json(*a)
      result = {
        name: self.object_name,
        json_class: "Chef::DataBagItem",
        chef_type: "data_bag_item",
        data_bag: self.data_bag,
        raw_data: encoded_data
      }
      result.to_json(*a)
    end
  end
end

