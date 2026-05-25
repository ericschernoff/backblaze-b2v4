use strict;
use Test::More;
use File::Spec;
eval q{ use Test::Spellunker v0.2.2 };
plan skip_all => "Test::Spellunker is not installed." if $@;

plan skip_all => "no ENV[HOME]" unless $ENV{HOME};
my $spelltest_switchfile = ".spellunker.en";
plan skip_all => "no ~/$spelltest_switchfile" unless -e File::Spec->catfile($ENV{HOME}, $spelltest_switchfile);

add_stopwords('Backblaze-B2V4');
add_stopwords(@{["Eric","Chernoff","Eric","Chernoff","Eric","Chernoff","/","BUGS"]});

all_pod_files_spelling_ok('lib');

