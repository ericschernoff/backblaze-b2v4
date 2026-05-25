use strict;
use Test::More;

eval q{ use Test::PAUSE::Permissions 0.04 };
plan skip_all => "Test::PAUSE::Permissions is not installed." if $@;

all_permissions_ok({dev => 1});
