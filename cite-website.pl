#! env perl

use strict;
use warnings;
use Switch;

use Data::Dumper;
use LWP::Simple qw();
use Data::OpenGraph;
use YAML qw();
use DateTime::Format::ISO8601;
use IO::Handle;
use Scalar::Util qw(reftype);

use Carp;
local $SIG{__WARN__} = sub { print( Carp::longmess (shift) ); };

STDOUT->binmode(":utf8");
STDERR->binmode(":utf8");

my $htmldoc = LWP::Simple::get($ARGV[0]);
die "Could not get $ARGV[0]. $@" unless defined $htmldoc;

my $og = Data::OpenGraph->parse_string($htmldoc);
#print STDERR "og: ", Dumper($og), "\n";


my %entry = ();

sub test {
    my $x = $_[0];
    return defined ($x)
        && ((ref $x ne ''
             && reftype($x) eq 'ARRAY'
             && scalar @$x)
            || length ($x));
}

my $title = $og->property('title');
if (test $title) {
    $entry{'title'} = $title;
}

my $og_type = $og->property('_basictype');
if (test $og_type) {
    my $type;
    switch ($og_type) {
        case "article" { $type = "article"; }
        case "book" { $type = "book"; }
        case "website" { $type = "website"; }
        else { $type = "website"; }
    }
    $entry{'type'} = $type;
}

my $url = $og->property('url');
if (test $url) {
    $entry{'URL'} = $url;
}
else {
    $entry{'URL'} = $ARGV[0];
}

my $id = undef;
my @creators = ();
print STDERR "og: ", Dumper($og), "\n";
if (test $og->property("$og_type:author")) {
    if (ref $og->property("$og_type:author") ne ''
        && reftype($og->property("$og_type:author")) eq 'ARRAY') {
        @creators = @{$og->property("$og_type:author")};
    }
    else {
        @creators[0] = $og->property("$og_type:author");
    }
}
#print STDERR "creators: ", Dumper(\@creators), "\n";
if (scalar @creators) {
    foreach my $creator (@creators) {
        #print STDERR "creator: >$creator<\n";
        my $creator_text = $creator;
        my $author = {};
        if ($creator_text =~ /^\s*([^,]+)\s*,\s*(.*\S)\s*$/) {
            my $family = $1;
            my $given = $2;
            $author->{'family'} = $family;
            $author->{'given'} = $given;
        }
        elsif ($creator_text =~ /^\s*(\S+\s+|\S+)+\s+(\S+)\s*$/) {
            my $family = $2;
            my $given = $1;
            $author->{'family'} = $family;
            $author->{'given'} = $given;
        }
        else {
            $author->{'family'} = $creator_text;
        }

        if (! $id) {
            $id = $author->{'family'};
            $id =~ s/\W//g;
            $id = lc $id;
        }

        push @{$entry{'author'}}, $author;
    }
    $entry{'id'} = $id;
}


sub date_conversion {
    my $date = $_[0];
    my $year = $date->year;
    my $month = $date->month;
    my $day = $date->day;

    my $issued;
    if ($year && $month && $day) {
        $issued = {'date-parts' => [[$year, $month, $day]]};
    }
    elsif ($year) {
        $issued = [{'year' => $year}];
    }
    else {
        print STDERR "Unrecognizable date.\n";
    }
}

my $og_issued_date_str;
switch ($og_type) {
    case "article" {
        $og_issued_date_str = $og->property("$og_type:published_time"); }
    case "book" {
        $og_issued_date_str = $og->property("$og_type:release_date"); }
}
#print STDERR "published time: ", $og_issued_date_str // "(undef)", "\n";
if (test $og_issued_date_str) {
    my $date = DateTime::Format::ISO8601->parse_datetime($og_issued_date_str);
    my $year = $date->year;

    $entry{'issued'} = date_conversion $date;

    if (exists $entry{'id'} && $year) {
        $entry{'id'} .= $year;
    }
}

my $publisher = $og->property('site_name');
if (test $publisher) {
    $entry{'publisher'} = $publisher;
}

if ($og_type eq 'book'
    && test $og->property("$og_type:isbn")) {
    $entry{'ISBN'} = $og->property("$og_type:isbn");
}

my @og_tags = ();
#print STDERR "tags: ", Dumper($og->property("$og_type:tag")), "\n";
if (test $og->property("$og_type:tag")) {
    if (ref $og->property("$og_type:tag") ne ''
        && reftype($og->property("$og_type:tag")) eq 'ARRAY') {
        @og_tags = @{$og->property("$og_type:tag")};
    }
    else {
        @og_tags[0] = $og->property("$og_type:tag");
    }
}
#print STDERR "tags: ", Dumper(\@og_tags), "\n";
if (scalar @og_tags) {
    $entry{'keyword'} = join ", ", @og_tags;
}

$entry{'accessed'} = date_conversion(DateTime->today());

print "\n", YAML::Dump([\%entry]), "\n...\n";
