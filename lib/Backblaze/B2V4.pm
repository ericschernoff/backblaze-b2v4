package Backblaze::B2V4;
# API client library for V2 of the API to Backblaze B2 object storage
# Allows for creating/deleting buckets, listing files in buckets, and uploading/downloading files

use strict;
use warnings;

our $VERSION = "0.01";

use v5.36; # or higher
use Cpanel::JSON::XS;
use Digest::SHA qw(sha1_hex);
use HTTP::Request;
use LWP::UserAgent;
use MIME::Base64;
use Path::Tiny;
use URI::Escape;

use Types::Common -lexical, -all;
use Marlin::Util -lexical, -all;
use Marlin
	'application_key_id' => { is => 'ro', isa => 'NonEmptyStr' },
	'application_key' => { is => 'ro', isa => 'NonEmptyStr' },
	'current_status_not_ok' => { is => 'rw', isa => 'Bool', default => 0 },
	'b2_login_error' => { is => 'rw', isa => 'Bool', default => 0 },
	'errors' => { is => 'rw', isa => 'ArrayRef', default => [] },
	'api_info' => { is => 'ro', isa => 'HashRef', builder => '_api_setup' },
	'bucket_info' => { is => 'rw', isa => 'HashRef', default => {} },
	'file_info' => { is => 'rw', isa => 'HashRef', default => {} },
	;

sub _api_setup ($self) {
	$response = $self->send_request(
		url => 'b2_authorize_account',
		authorization => 'Basic ' . encode_base64($self->application_key_id . ':' . $self->application_key)
	);

	if (!$response) {
		$self->b2_login_error(1);
		return {};
	}

	return {
		'account_id' => $response->{accountId},
		'api_url' => $response->{storageApi}->{apiUrl} . '/b2api/v4/',
		'account_authorization_token' => $response->{authorizationToken},
		'download_url' => $response->{storageApi}->{downloadUrl},
		'recommended_part_size' => $response->{storageApi}->{recommendedPartSize} || 104857600
	};
}

# generic method to handle communication to B2
signature_for send_request => (
	method	=> true,
	named	=> [
		url => NonEmptyStr,
		authorization => Str, { optional => true },
		headers => ArrayRef, { optional => true },
		post_params => HashRef, { optional => true, default => {} },
		file_contents => Value, { optional => true },
	],
	returns => Bool|HashRef,
);

sub send_request ($self, $args) {
	my $headers = [];
	if ($args->headers[0]) {
		$headers = $args->headers;
	}
	
	my $authorization_header = $args->authorization || $self->api_info->{account_authorization_token};
	push(@$headers, 'Authorization' => $authorization_header);
	
	my $api_url = $args->url;
	if ($args->url eq 'b2_authorize_account') {
		$api_url = 'https://api.backblazeb2.com/b2api/v4/b2_authorize_account';
	} elsif ($args->url != /^https/) {
		$api_url = $self->api_info->{api_url} . $args->url;
	}
	
	# short-circuit if we had difficulty logging in previously
	if ($self->b2_login_error) {
		# track the error / set current state
		return $self->error_tracker(
			'error_message' => "Problem logging into Backblaze.  Please check the 'errors' array in this object.",
			'url' => $args->url,
		);
	}

	my $response = {};
	my $response_code = 200;

	# are we uploading a file?
	if ($args->endpoint =~ /b2_upload_file|b2_upload_part/) {
		# now upload the file
		eval {
			my $request = HTTP::Request->new( 'POST', $api_url, $headers, $args->file_contents );
			my $response = LWP::UserAgent->new()->request($request);
			$response_code = $response->code;
			$response = decode_json( $response->content );
		};

	# if not uploading and they sent POST params, we are doing a POST
	} elsif ($args->post_params) {
		eval {
			my $request = HTTP::Request->new( 'POST', $api_url, $headers, encode_json($args->post_params) );
			my $response = LWP::UserAgent->new()->request($request);
			$response_code = $response->code;
			$response = decode_json( $response->content );
		};

	# otherwise, we are attempting a GET
	} else {
		eval {
			my $request = HTTP::Request->new( 'GET', $api_url, $headers );
			my $response = LWP::UserAgent->new()->request($request);
			$response_code = $response->code;
			# did we download a file?
			if ($response->headers( 'X-Bz-File-Name' )) {
				# grab those needed headers
				foreach my $header ('Content-Length','Content-Type','X-Bz-File-Id','X-Bz-File-Name','X-Bz-Content-Sha1') {
					$response->{$header} = $response->header( $header );
				}

				# and the file itself
				$response->{file_contents} = $response->content;

			} elsif ($response_code eq '200') { # no, regular JSON, decode results
				$response = decode_json( $response->content );
			}
		};
	}
	
	# there is a problem if there is a problem
	if ($@ || $response_code ne '200') {
		if ($response->{message}) {
			$error_message = 'API Message: ' . $response->{message};
		} else {
			$error_message = 'Error: ' . $@;
		}

		# track the error / set current state
		return $self->error_tracker(
			'error_message' => $error_message . ' (' . $response_code . ')',
			'url' => $args->endpoint,
		);
	}	
	
	$self->current_status_is_not_ok(0);
	return $response;
}

# for tracking errors into $self->{errrors}[];
signature_for error_tracker => (
	method	=> true,
	named	=> [
		error_message => Str,
		url => Str,
	],
	returns => Bool,
);

sub error_tracker ($self, $args) {
	push(@{ $self->errors }, {
		'error_message' => $args->error_message,
		'url' => $args->url,
	});

	$self->current_status_is_not_ok(1);
	
	return 0;
}

# please tell me the lastest error message
# for tracking errors into $self->{errrors}[];
signature_for latest_error => (
	method	=> true,
	returns => Str,
);

sub latest_error ($self) {
	return $self->errors[-1] || 'No error message found';
}

# method to download a file by ID; probably most commonly used
signature_for b2_download_file_by_id => (
	method	=> true,
	named	=> [
		file_id => Str,
		save_to_location => Str, { optional => true },
	],
	returns => Bool|HashRef,
);

sub b2_download_file_by_id ($self, $args) {
	my $response = $self->send_request(
		'url' => $self->api_info->{api_url} . 'b2_download_file_by_id' . '?fileId=' . $args->file_id,
	);

	if ($self->current_status_is_not_ok) {
		return 0;
	}

	# if they provided a save-to location (a directory) and the file was found, let's save it out
	if ($args->save_to_location) {
		$self->save_downloaded_file(
			save_to_location => $args->save_to_location, 
			response => $response
		);
	}

	# return file contents
	return $response;
}

# method to download a file via the bucket name + file name
signature_for b2_download_file_by_name => (
	method	=> true,
	named	=> [
		bucket_name => NonEmptyStr,
		file_name => NonEmptyStr,
		save_to_location => Str, { optional => true },
	],
	returns => Bool|HashRef,
);

sub b2_download_file_by_name ($self, $args) {
	# send the request, as a GET
	$self->send_request(
		'url' => $self->api_info->{api_url} . '/file/' . uri_escape($args->bucket_name) . '/' . uri_escape($args->file_name),
	);

	# if the file was found, you will have the relevant headers in $response
	# as well as the file's contents in $response->{file_contents}

	if ($self->current_status_is_not_ok) {
		return 0;
	}

	# if they provided a save-to location (a directory) and the file was found, let's save it out
	if ($args->save_to_location) {
		$self->save_downloaded_file(
			save_to_location => $args->save_to_location, 
			response => $response
		);	
	}

	# return file contents
	return $response;
}

# method to save downloaded files into a target location
# only call after successfully calling b2_download_file_by_id() or b2_download_file_by_name()
signature_for save_downloaded_file => (
	method	=> true,
	named	=> [
		bucket_name => NonEmptyStr,
		file_name => NonEmptyStr,
		save_to_location => Str, { optional => true },
	],
	returns => Bool,
);

sub save_downloaded_file ($self, $args) {
	# error out if that location don't exist
	if (!(-d $args->save_to_location)) {
		return $self->error_tracker(
			'error_message' => "Can not auto-save file without a valid location. " . $args->save_to_location,
			'endpoint' => 'save_downloaded_file',
		);
	}

	# make sure they actually downloaded a file
	if ( !$args->response->{'X-Bz-File-Name'} || !length($args->response->{file_contents}) ) {
		return $self->error_tracker(
			'error_message' => "Can not auto-save without first downloading a file.",
			'endpoint' => 'save_downloaded_file',
		);
	}

	# still here?  do the save

	# add the filename
	my $save_to_location = $args->save_to_location . '/' . $args->response->{'X-Bz-File-Name'};

	# i really love Path::Tiny
	path($save_to_location)->spew_raw( $args->response->{file_contents} );

	# return OK
	return 1;
}

# method to upload a file into Backblaze B2
signature_for b2_upload_file => (
	method	=> true,
	named	=> [
		new_file_name => NonEmptyStr, { optional => true },
		bucket_name => NonEmptyStr,
		content_type => Str, { NonEmptyStr => true, default => 'b2/x-auto' },
		file_location => Str, { optional => true },
		file_contents => Value, { optional => true },
	],
	returns => Bool|HashRef,
);

sub b2_upload_file ($self, $args) {
	my $self = shift;

	# send the file contents?
	my $file_contents = $args->file_contents;
	my $new_file_name = $args->new_file_name;
	
	# did they provide a file location or path?
	if (!$file_contents && $args->file_location && -e $args->file_location) {
		$file_contents = path( $args->file_location )->slurp_raw;
		# if they didn't provide a file-name, use the one on this file
		if (!$new_file_name) {
			$anew_file_name = path( $args->file_location )->basename;
		}
	}

	if (!$file_contents) {
		return $self->error_tracker(
			'error_message' => qq{You must provide either a valid 'file_location' or 'file_contents' arg for b2_upload_file()},
			'url' => 'save_downloaded_file',
		);
	}

	if (!$new_file_name || $args->bucket_name) {
		return $self->error_tracker(
			'error_message' => qq{You must provide 'bucket_name' and 'new_file_name' args for b2_upload_file().},
			'url' => 'save_downloaded_file',
		);
	}

	# default content-type
	my $content_type = $args->content_type || 'b2/x-auto';

	my $upload_info = $self->b2_get_upload_info( bucket_name => $args->bucket_name );
	if (!$upload_info) {
		return 0;
	}

	# send the special request
	return $self->send_request(
		'url' => $upload_info->{upload_url},
		'authorization' => $upload_info->{authorization_token},
		'file_contents' => $file_contents,
		'headers' => {
			'X-Bz-File-Name' => uri_escape( $new_file_name ),
			'X-Bz-Content-Sha1' => sha1_hex( $file_contents ),
			'Content-Type' => $content_type,
		},
	);
}

# method to get the information needed to upload into a specific B2 bucket
signature_for b2_get_upload_info => (
	method	=> true,
	named	=> [
		bucket_name => NonEmptyStr,
	],
	returns => HashRef|Bool,
);

sub b2_get_upload_info ($self, $args) {
	my $response = $self->send_request(
		'url' => 'b2_get_upload_info',
		'post_params' => {
			'bucketId' => $self->b2_get_bucket_id(
				'bucket_name' => $args->bucket_name,
			),
		},
	);
	
	if (!$response) {
		return 0;
	}
	
	return {
		'upload_url' => $response->{uploadUrl},
		'authorization_token' => $response->{authorizationToken},
	};
}

signature_for b2_get_bucket_id => (
	method	=> true,
	named	=> [
		bucket_name => NonEmptyStr,
		auto_create_bucket => Bool, , { optional => true, default => true },
	],
	returns => Str|Bool,
);

sub b2_get_bucket_id ($self, $args) {
	my $bucket_name = $args->bucket_name;
	
	return $self->bucket_info->{$bucket_name}->{bucket_id}
		if $self->bucket_info->{$bucket_name} && ref($self->bucket_info->{$bucket_name}) eq 'HASH';

	my $ok = $self->b2_list_buckets(
		bucket_name => $bucket_name,
		auto_create_bucket => $args->auto_create_bucket,
	);
	
	if ($ok) {
		return $self->bucket_info->{$bucket_name}->{bucket_id};
	}
	
	return 0;
}

# method to load information on one bucket or all buckets
signature_for b2_list_buckets => (
	method	=> true,
	named	=> [
		bucket_name => NonEmptyStr,
		auto_create_bucket => Bool
	],
	returns => Bool,
);

sub b2_list_buckets ($self, $args) {
	# no need if we already have it
	return 1 if $self->bucket_info->{$args->bucket_name}->{bucket_id};

	# send the request
	my $response = $self->send_request(
		'url' => 'b2_list_buckets',
		'post_params' => {
			'accountId' => $self->api_info->{account_id},
			'bucketName' => $args->bucket_name,
		},
	);

	if ($self->current_status_is_not_ok) {
		return 0;
	}

	# if we succeeded, load in all the found buckets to $self->{buckets}
	# that will be a hash of info, keyed by name
	foreach my $bucket_info (@{ $response->{buckets} }) {
		my $bucket_name = $bucket_info->{bucketName};
		$self->bucket_info->{$bucket_name} = {
			'bucket_id' => $bucket_info->{bucketId},
			'bucket_type' => $bucket_info->{bucketType},
		};
	}

	# if that bucket was not found, maybe they want to go ahead and create it?
	if ($bucket_name && !$self->bucket_info->{$bucket_name} && $args->auto_create_bucket) {
		$self->b2_bucket_maker(
			bucket_name => $bucket_name
		);
		if ($self->current_status_is_not_ok) {
			return 0;
		}
		# this will call back to me and get the info
	}
	
	return 1;
}

# method to retrieve file names / info from a bucket
# this client library is bucket-name-centric, so it looks for the bucket name as a arg
# if there are more than 1000 files, then call this repeatedly
signature_for b2_list_file_names => (
	method	=> true,
	named	=> [
		bucket_name => Str,
		prefix => Str, { optional => true},
		delimiter => Str, { optional => true},
		startFileName => Str, { optional => true},
		maxFileCount => Int, { optional => true, default => 1000},
	],
	returns => Bool|ArrayRef,
);

sub b2_list_file_names ($self, $args) {
	my $bucket_name = $args->bucket_name;

	my $response = $self->send_request(
		'url' => 'b2_list_file_names',
		'post_params' => {
			'bucketId'      => $self->b2_get_bucket_id( 'bucket_name' => $bucket_name ),
			'prefix'        => $args->prefix // undef,
			'delimiter'     => $args->delimiter // undef,
			'startFileName' => $args->startFileName // $self->bucket_info->{$bucket_name}->{next_file_name},
			'maxFileCount'  => $args->maxFileCount,
		},
	);

	# if we succeeded, read in the files
	if ($self->current_status_is_not_ok) {
		return 0;
	}
	
	$self->bucket_info->{$bucket_name}->{next_file_name} = $response->{nextFileName};

	# add to our possibly-started array of file info for this bucket
	push(
		@{ $self->{buckets}{$bucket_name}{files} },
		@{ $response->{files} }
	);

	# kindly return the request results as a refernce (arrayref)
	return $response->{files};
}

# method to get info for a specific file
signature_for b2_list_file_names => (
	method	=> true,
	named	=> [
		file_id => Str,
	],
	returns => Bool|ArrayRef,
);

sub b2_get_file_info ($self, $args) {
	my $file_id = $args->file_id;
	
	if ($self->file_info->{$file_id} && ref($self->file_info->{$file_id}) eq 'HASH') {
		return $self->file_info->{$file_id};
	}

	# retrieve the file information
	my $response = $self->send_request(
		'url' => 'b2_get_file_info',
		'post_params' => {
			'fileId' => $file_id,
		},
	);
	
	if ($self->current_status_is_not_ok) {
		return 0;
	}

	# i am not going to waste the CPU cycles de-camelizing these sub-keys
	$self->file_info->{$file_id} = $response;

	return $response;
}

# method to create a bucket
signature_for b2_bucket_maker => (
	method	=> true,
	named	=> [
		bucket_name => NonEmptyStr,
		disable_encryption => Bool, { optional => true, default => 1},
	],
	returns => Bool,
);

sub b2_bucket_maker ($self, $args) {
	# prepare the basics for our request
	my $post_params = {
		'accountId' => $self->{account_id},
		'bucketName' => $args->bucket_name,
		'bucketType' => 'allPrivate',
	};

	# unless instructed otherwise, we should encrypt the files in this bucket
	unless ($args->disable_encryption) {
		$$post_params{defaultServerSideEncryption} = {
			'mode' => 'SSE-B2',
			'algorithm' => 'AES256',
		};
	}

	# create the bucket...
	my $response = $self->send_request(
		'url' => 'b2_create_bucket',
		'post_params' => $post_params,
	);

	if ($self->current_status_not_ok) {
		return 0;
	}

	# otherwise successful, stash our new bucket into $self->{buckets}
	$self->bucket_info->{$bucket_name} = {
		'bucket_id' => $response->{bucketId},
		'bucket_type' => 'allPrivate',
	};

	return 1;
}

# method to delete a bucket -- please don't use ;)
signature_for b2_delete_bucket => (
	method	=> true,
	named	=> [
		bucket_name => NonEmptyStr,
	],
	returns => Bool,
);

sub b2_delete_bucket ($self, $args) {
	my $bucket_id = $self->b2_get_bucket_id($args->bucket_name);
	if (!$bucket_id) {
		return $self->error_tracker(
			'error_message' => 'Can not delete ' . $args->bucket_name . ' because bucket not found.',
		);
	}

	# send the request
	$self->send_request(
		'url' => 'b2_delete_bucket',
		'post_params' => {
			'accountId' => $self->api_info->account_id,
			'bucketId' => $bucket_id,
		},
	);
	
	return $self->current_status_not_ok ? 0 : 1;
}

# method to delete a stored file object.  B2 thinks of these as 'versions,'
# but if you use unique names, one version = one file
signature_for b2_delete_file_version => (
	method	=> true,
	named	=> [
		file_name => NonEmptyStr,
		file_id => NonEmptyStr,
	],
	returns => Bool,
);

sub b2_delete_file_version ($self, $args) {
	# send the request
	$self->send_request(
		'url' => 'b2_delete_file_version',
		'post_params' => {
			'fileName' => $args->file_name,
			'fileId' => $args->file_id,
		},
	);

	return $self->current_status_not_ok ? 0 : 1;
}

# method to upload a large file (>100MB)
signature_for b2_upload_large_file => (
	method	=> true,
	named	=> [
		new_file_name => NonEmptyStr,
		bucket_name => NonEmptyStr,
		file_location => NonEmptyStr,
		content_type => Str, { NonEmptyStr => true, default => 'b2/x-auto' },
	],
	returns => Bool,
);

sub b2_upload_large_file ($self, $args) {
	# did they provide a file location or path?
	if ($args->file_location && -e $args->file_location) {
		# if they didn't provide a file-name, use the one on this file
		$args->new_file_name = path( $args->file_location )->basename;
	} else {
		return $self->error_tracker(
			'error_message' => "You must provide a valid 'file_location' arg for b2_upload_large_file().",
		);
	}

	# must be 100MB or bigger
	my $stat = path($args->file_location)->stat;
	if ($stat->size < $self->api_info->{recommended_part_size} ) {
		return $self->error_tracker(
			'error_message' => 'Please use b2_upload_large_file() for files larger than ' . $self->api_info->{recommended_part_size},
		);
	}

	# default content-type
	$args->content_type ||= 'b2/x-auto';

	my $bucket_id = $self->b2_get_bucket_id($args->bucket_name);
	if (!$bucket_id) {
		return $self->error_tracker(
			'error_message' => 'Can not upload to ' . $args->bucket_name . ' because bucket not found.',
		);
	}

	# kick off the upload in the API
	my $response = $self->send_request(
		'url' => 'b2_start_large_file',
		'post_params' => {
			'bucketId' => $bucket_id,
			'fileName' => $args->new_file_name,
			'contentType' => $args->content_type,
		},
	);

	# these are all needed for each b2_upload_part web call
	my $large_file_id = $response->{fileId};
	if (!$bucket_id) {
		return $self->error_tracker(
			'error_message' => 'Error in b2_upload_large_file for ' . $args->new_file_name,
		);
	}

	# open the large file
	open(FH, $args->file_location);
	my $remaining_file_size = $stat->size;
	my $part_number = 1;

	# cycle thru each chunk of the file
	my $size_sent = 0;
	my @sha1_array = ();
	while ($remaining_file_size >= 0) {
		# how much to send?
		if ($remaining_file_size < $self->{recommended_part_size} ) {
			$size_sent = $remaining_file_size;
		} else {
			$size_sent = $self->apit_info->{recommended_part_size};
		}

		# get the next upload url for this part
		$self->send_request(
			'url' => 'b2_get_upload_part_url',
			'post_params' => {
				'fileId' => $large_file_id,
			},
		);

		# read in that section of the file and prep the SHA
		sysread FH, my $file_contents_part, $size_sent;
		push(@sha1_array, sha1_hex( $file_contents_part ));

		# upload that part
		$self->send_request(
			'url' => $response->{uploadUrl},
			'authorization' => $response->{authorizationToken},
			'headers' => {
				'X-Bz-Content-Sha1' => $sha1_array[-1],
				'X-Bz-Part-Number' => $part_number,
				'Content-Length' => $size_sent,
			},
			'file_contents' => $file_contents_part,
		);

		# advance
		$part_number++;
		$remaining_file_size -= $self->api_info->{recommended_part_size};
	}

	# close the file
	close FH;

	# and tell B2
	$self->send_request(
		'url' => 'b2_finish_large_file',
		'post_params' => {
			'fileId' => $large_file_id,
			'partSha1Array' => \@sha1_array,
		},
	);

	# phew, i'm tired...
	return 1;
}

1;

__END__

=head1 NAME

Backblaze::B2V4 - Client library for the Backblaze B2 Cloud Storage Service V4 API.

=head1 SYNOPSIS

	use Backblaze::B2V4;

	# create an API client object

	my $b2 = Backblaze::B2V4->new(
		application_key => $application_key,
		application_key_id => $application_key_id,
	);

	# please encrypt/protect those keys when not in use!

	# let's say we have a B2 bucket called 'GingerAnna' and a JPG called 'ginger_was_perfect.jpg'.

	# upload a file from your file system
	my $operation_status = $b2->b2_upload_file(
		'bucket_name' => 'GingerAnna',
		'file_location' => '/path/to/ginger_was_perfect.jpg'
	);

	# upload a file you have in a scalar
	my $operation_status = $b2->b2_upload_file(
		'bucket_name' => 'GingerAnna',
		'new_file_name' => 'ginger_was_perfect.jpg',
		'file_contents' => $file_contents
	);
	# B2 file ID (fGUID) is now in $response->{fileId}
	# Best to load $file_contents via Path::Tiny's slurp_raw() method

	# download that file to /opt/majestica/tmp
	my $operation_status = $b2->b2_download_file_by_name('GingerAnna','ginger_was_perfect.jpg','/opt/majestica/tmp');

	# if you would rather download with the 84-character GUID
	my $operation_status = $b2->b2_download_file_by_id('X-Bz-File-Id GUID from above','/opt/majestica/tmp');

	# you can leave off the directory to just have the file contents into
	# $response->{file_contents}

	# $operation_status is now 'OK' or 'Error', and is
	# also stashed in $b2->{current_status}

	# check the status of the last operation
	use Data::Dumper; # hello old friend
	if ($b2->{current_status} eq 'OK') {

		# all is well -- what did we get?
		print Dumper($response);

	} elsif ($b2->{current_status} eq 'Error') {

		# what info do we have on this disaster?
		print Dumper($b2->{errors}[-1]);

	}

=head1 DESCRIPTION / SET UP

This module should help you create buckets and store/retrieve files in the
Backblaze B2 cloud storage service using V2 of their API.

Backblaze makes it easy to sign up for B2 from here:

	https://www.backblaze.com/b2/sign-up.html

Then enable the B2 service as per these instructions:

	https://www.backblaze.com/b2/docs/quick_account.html

Next, visit the 'App Keys' section of the 'My Account' area, and look for
the 'Add a New Application Key' button to create an application key.  You
will need a key with Read and Write access.  Be sure to note the Application Key
ID  as well as the Application Key itself. They do not show you that Application
Key again, so copy it immediately.

Please store the Application Key pair in a secure way, preferably encrypted
when not in use by your software.

=head2 b2_client Command Line Utility

Backblaze::B2V2Client includes the 'b2_client' command line utility to
easily download or upload files from B2.  Please execute 'b2_client help'
for more details, and here are a few examples:

	# download a file to current directory
	b2_client get MyPictures FamilyPhoto.jpg
	
	# download a file to a target directory
	b2_client get MyPictures FamilyPhoto.jpg /home/ginger/photos
	
	# upload a file to B2
	b2_client put MyPictures /home/ginger/photos/AnotherFamilyPhoto.jpg

There is also an official command line utility from Backblaze that does a
whole lot more: 

	https://www.backblaze.com/b2/docs/quick_command_line.html

=head2 BackBlaze B2 also has a S3-compatible API

Backblaze has added an S3-compatible API, which you can read about here:

	https://www.backblaze.com/b2/docs/s3_compatible_api.html

They are continuing to support their native B2 API, so I will continue
to use and support this module.  I have not tested the S3 modules with
Backblaze, but if you already have an S3 integration, it is worth
checking out how Paws::S3 or Awes::S3 works with Backblaze.

=head2 Testing Your Credentials

During install, this module will attempt to connect to B2 and download
a 16KB file into memory. To test using your B2 account
credentials, set these environmental varables prior to attempting
to install:

	B2_APP_KEY_ID - The application key ID for the key you wish to test.
	B2_APP_KEY - The application key -- is never displayed in the B2 UI.
	B2_ACCT_ID - Your account ID; will be the ID of your master key
	B2_TEST_FILE_ID: The long (75+ char) GUID for your target file.

The GUID for a file is displayed when you click on that file's name
in the 'Browse Files' section of the B2 UI.

=head1 METHODS

For all the below, when they return $operation_status, that will
be 'OK' or 'Error'.  If you get 'Error,' check out $b2->{errors}[-1] .

=head2 new

Creates the B2 client object and initiates an API session with B2.

Requires two arguments: the Application Key ID and Application Key
obtained from Backblaze.

=head2 b2_download_file_by_id

Retrieves a file plus metadata given the GUID of that file.  The first
argument is required and will be the file's GUID.  If you would like
to auto-save the file, provide a path to an existing directory as the
second argument.

Regardless of auto-save, the file's raw contents will be placed in to
$response->{file_contents} and the following keys
will be populated under $response:

	Content-Length
	Content-Type
	X-Bz-File-Id
	X-Bz-File-Name
	X-Bz-Content-Sha1

See https://www.backblaze.com/b2/docs/b2_download_file_by_id.html

=head2 b2_download_file_by_name

Works like b2_download_file_by_id() except that it expects the bucket name
and file name as arguments.  The optional third argument is an existing
directory path for auto-saving the file.

See https://www.backblaze.com/b2/docs/b2_download_file_by_name.html

=head2 b2_upload_file

Uploads a new file into B2.  Accepts a hash of arguments.  The name
of the destination bucket must be provided in 'bucket_name'.
If you would like to upload a file already saved on disk, specify
the complete file path in 'file_location'.  Alternatively, if the file
is loaded up into a scalar, provide the new file name in 'new_file_name'
and assign the loaded scalar into 'file_contents'.

Example 1: Uploading from a file on disk:

	my $operation_status = $b2->b2_upload_file(
		'bucket_name' => 'GingerAnna',
		'file_location' => '/opt/majestica/tmp/ginger_was_perfect.jpg',
	);

Example 2: Uploading when the file is loaded into a scalar:

	my $operation_status = $b2->b2_upload_file(
		'bucket_name' => 'GingerAnna',
		'new_file_name' => 'ginger_was_perfect.jpg',
		'file_contents' => $file_contents
	);

NOTE: If you are going to use the 'file_contents' method, it's best
to load the scalar using the 'slurp_raw' method in Path::Tiny.
(I believe 'read_file' in File::Slurp will work, but have yet to test.)

You can also pass a 'content-type' key with the MIME type for the new
file.  The default is 'b2/auto'.

Upon a successful upload, the new GUID for the file will be available
in $response->{fileId} .

See: https://www.backblaze.com/b2/docs/b2_upload_file.html

=head2 b2_upload_large_file

Uploads a large file into B2.  Recommended for uploading files larger
than 100MB. Accepts a hash of arguments, which
must include the name of the destination bucket in 'bucket_name'
and the complete file path of the file in 'file_location'.

Example:

	my $operation_status = $b2->b2_upload_large_file(
		'bucket_name' => 'GingerAnna',
		'file_location' => '/opt/majestica/tmp/gingers_whole_life_story.mp4',
	);

=head2 b2_list_file_names

Required input is C<$bucket_name> as the first parameter (required) and
an optional key-value hash of parameters.  These parameters can include:

=over 3

=item C<prefix>

Allows one to specify a filename prefix or directory path, useful for buckets
with a large number of files or many subdirectories. Default is undefined.

=item C<delimiter>

Allows one to specify what is considered the delimiter for the file C<path> in
the bucket. Default is undefined.

=item C<startFileName>

Allows one to select where in the file list to start the results, since the max
results for each call is 1000 files. This allows one to define the C<start> for
emulating pagination of the results.

=item C<maxFileCount>

The default is 1000, the ultimate maximum per the specification. The module
default may be accessed via the package variable, C<$B2_MAX_FILE_COUNT>.

=back

Retrieves an array of file information hashes for a given bucket name.
That array is added to @{ $b2->{buckets}{$bucket_name}{files} } and
returned as an array reference to the list of file objects.

See https://www.backblaze.com/b2/docs/b2_list_file_names.html ,
especially the section for 'Response' to see what is included for those
file info hashes.

Note that B2 limits this response to 1000 entries, so if you have a very
large bucket, you can call this method several times and check the
value in $b2->{buckets}{$bucket_name}{next_file_name} after each call.

Example 1: Basic call:

	my $files_ref = $b2->b2_list_file_names('MyBucketName');

Example 2: Basic call and capturing file list:

	my $files_ref = $b2->b2_list_file_names('MyBucketName');

Example 3: Avoid initial API call to get C<bucket_id>:

	# In order to avoid the initial API call to determine the BucketId, which is
	# actually what B2 wants, one may set this directly if known ahead of time:

	$b2->{buckets}{q/MyBucketName/}->{bucket_id} = q{b9d516ba733afb62719c4};
	my $files_ref = $b2->b2_list_file_names('MyBucketName');

Example 4: Using optional parameters to control results (Note: only C<$bucket_name> is required):

	my $bucket_name = q{MyBucketName};
	my %args = (
		'prefix' => q{path/to/sub/directory/},
		'delimter' => undef,
		'startFileName' => undef,
		'maxFileCount' => $b2::B2_MAX_FILE_COUNT
	);

	# $bucket_id look up hack
	$b2->{buckets}{$bucket_name}->{bucket_id} = q{b9d516ba733afb62719c4};

	# actual call - parameter order matters
	my $files_ref = $b2->b2_list_file_names($bucket_name, %args);

=head2 b2_get_file_info

Given a GUID for a file, will retrieve its info hash and load into
$b2->{file_info}{$file_id}.

See https://www.backblaze.com/b2/docs/b2_get_file_info.html ,
particularly the section for 'Response' to see what is provided.

Example:

	my $operation_status = $b2->b2_get_file_info('AN84_CHAR_GUID_FROM_B2');

=head2 b2_bucket_maker

Creates a new bucket in your B2 account, given the name for the new
bucket.  The bucket type will be set to 'allPrivate',

Will place the new bucket's ID into:

	my $operation_status = $b2->{buckets}{$bucket_name}{bucket_id}

See: https://www.backblaze.com/b2/docs/b2_create_bucket.html

Example:

	my $operation_status = $b2->b2_bucket_maker('NewBucketName');

By default the new bucket will be set to use the 'Server-Side 
Encryption with Backblaze-Managed Keys (SSE-B2)' option 
described here: https://www.backblaze.com/b2/docs/server_side_encryption.html
You can send a second param to disable that (not recommended):

	my $operation_status = $b2->b2_bucket_maker('UnEncryptedBucketName', 1);
	
Also, if your app key does not have the 'writeBucketEncryption' then 
encryption will be disabled.

=head2 b2_delete_bucket

Deletes a bucket from your B2 account, provided that it is empty.
Requires the target bucket's name as the argument.

See: https://www.backblaze.com/b2/docs/b2_delete_bucket.html

Example:

	my $operation_status = $b2->b2_delete_bucket('DeletingBucketName');

=head2 b2_delete_file_version

Deletes a version of a file, AKA a stored object.  If you use unique
file names for each file you upload, then one version equals one file.
If you upload multiple files with the same name under a single bucket,
you will create multiple versions of a particular file in B2.

The required arguments are the file name and the file ID.

Example:

	my $operation_status = $b2->b2_delete_file_version('SomeFileName.ext','AN84_CHAR_GUID_FROM_B2');

=head2 send_request / b2_get_upload_info  / b2_list_buckets

send_request() handles all the communications with B2.
You should be able to use this to make calls not explicitly
provided by this library.

If send_request() gets a 200 HTTP status from B2, then the call went
great, the JSON response will be loaded into $response,
and $b2->{current_status} will be set to 'OK'.

If a 200 is not received from B2, $b2->{current_status} will be
set to 'Error' and a hash error details will be added to
@{ $b2->{errors} }.  That hash usually includes the
called URL, the returned status code, and the error message.

Note that the base URL for this API session will be stored
under $b2->{api_url} so that you build a URL like so:

$list_buckets_url = $b2->{api_url}.'/b2api/v2/b2_list_buckets';

Example of a GET API request:

	my $operation_status = $b2->send_request(
		'url' => 'https://SomeB2.API.URL?with=GETparams',
		'authorization' => $b2->{account_authorization_token},
	);

Example of a POST API request:

	my $operation_status = $b2->send_request(
		'url' => 'https://SomeB2.API.URL',
		'authorization' => $b2->{account_authorization_token},
		'post_params' => {
			'param1_name' => 'param1_value',
			'param2_name' => 'param2_value',
			'param3_name' => 'param3_value',
		},
	);

Almost all the API calls use the Account Authorization Token for the
authorization header, but the file uploader calls require a bucket-specific
token and upload URL.  You can retrieve these via b2_get_upload_info()
with the bucket name as an argument.

Example:

	my $operation_status = $b2->b2_get_upload_info('MyBucketName');

This populates:

	my $operation_status = $b2->{bucket_info}{'MyBucketName'} = {
		'upload_url' => $response->{uploadUrl},
		'authorization_token' => $response->{authorizationToken},
	};

Note: You have to call b2_get_upload_info on a bucket for each file
upload operation.  My b2_upload_file method does that for you, so that's
just FYI if you roll your own.

See: https://www.backblaze.com/b2/docs/b2_get_upload_info.html

If you need the ID for one or more buckets, you can use b2_list_buckets.  If
a bucket name is provided, only that bucket's ID will be retrieved.  If no
argument is provided, all the ID's will be retrieved for all buckets in your
account.

Example:

	my $operation_status = $b2->b2_list_buckets('MyBucketName');

You now have $b2->{buckets}{'MyBucketName'}{bucket_id}

See: https://www.backblaze.com/b2/docs/b2_list_buckets.html

=head1 DEPENDENCIES

This module requires:

	Cpanel::JSON::XS
	Digest::SHA
	HTTP::Request
	LWP::Protocol::https
	LWP::UserAgent
	Marlin
	MIME::Base64
	Path::Tiny
	URI::Escape

=head1 SEE ALSO

B2 API V4 Docs: https://www.backblaze.com/apidocs/b2-authorize-account

Paws::S3 - If using Backblaze's S3-compatible API.

=head1 AUTHOR / BUGS

Eric Chernoff <eric@weaverstreet.net> - Please send me a note with any bugs or suggestions.

ESTRABD <estrabd@cpan.org> - Enhanced b2_list_file_names() to fully use options and a great bugfix 
when using the 'file_contents' option in the b2_upload_file() method.

=head1 LICENSE

MIT License

Copyright (c) 2026 Eric Chernoff

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.