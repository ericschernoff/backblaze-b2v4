use strict;
use Test::More tests => 5;

use_ok $_ for qw(
    Backblaze::B2V4
);

# let them use ENV vars to test their account
my $application_key_id = $ENV{B2_APP_KEY_ID} || '002dcecbc999f31000000000e';
my $application_key =  $ENV{B2_APP_KEY} || 'K002cbUnOGDiTATcLQvac+pDTVjghC8';
my $account_id =  $ENV{B2_ACCT_ID} || 'dcecbc999f31';
my $test_file_id = $ENV{B2_TEST_FILE_ID} || '4_z1dbcfe6ccb7cb959793f0311_f111f065d1a8a36cf_d20200803_m192431_c002_v0001142_t0011';

# test logging in
my $b2 = Backblaze::B2V4->new(
	application_key => $application_key,
	application_key_id => $application_key_id,
);

my $connection_words = 'Could not connect or authenticate to Backblaze.  If you set your account ID and application keys, please check those and/or test with the included keys.  Please contact me if the supplied credentials are not working.';

ok($b2->api_info->{account_id} eq $account_id, $connection_words );
like($b2->api_info->{account_authorization_token}, qr/4\_$application_key_id/, $connection_words );

# test file download
my $b2_response = $b2->b2_download_file_by_id(file_id => $test_file_id);
ok( ref($b2_response) eq 'HASH', 'Test file could not be downloaded; B2 Msg: ' . $b2->latest_error() );
ok( length($b2_response->{file_contents}) > 15000, 'Test file did not download properly; B2 Msg: ' . $b2->latest_error() );

# that's enough for now
done_testing;