requires 'perl', '5.008001';

on 'test' => sub {
    requires 'Test::More', '0.98';
	requires 'Cpanel::JSON::XS', '4.11';
	requires 'Digest::SHA', '6.02';
	requires 'MIME::Base64', '3.15';
	requires 'Path::Tiny', '0.108';
	requires 'URI::Escape', '3.31';
    requires 'LWP', '6.28';
	requires 'LWP::Protocol::https','6.07';
};

