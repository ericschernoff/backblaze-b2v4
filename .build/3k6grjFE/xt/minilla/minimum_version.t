use Test::More;
eval "use Test::MinimumVersion::Fast 0.04";
if ($@) {
    plan skip_all => "Test::MinimumVersion::Fast required for testing perl minimum version";
}
all_minimum_version_from_metayml_ok();

