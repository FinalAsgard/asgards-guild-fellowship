package.path = "./?.lua;./?/init.lua;" .. package.path

local test = require("tests.test_helper")

require("tests.spec.client_profile_spec")
require("tests.spec.compatibility_spec")
require("tests.spec.command_router_spec")
require("tests.spec.persistence_spec")
require("tests.spec.libraries_spec")
require("tests.spec.lifecycle_spec")
require("tests.spec.bootstrap_spec")

if not test.run() then
    os.exit(1)
end
