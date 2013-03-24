module Billingly
  # The parent controller all Billingly controllers inherits from.
  # Defaults to ApplicationController. This should be set early
  # in the initialization process and should be set to a string.
  mattr_accessor :parent_controller
  @@parent_controller = "ApplicationController"

  def self.setup
    yield self
  end
end
require 'billingly/engine'
require 'billingly/rails/routes'
