#! env perl

use strict;
use warnings;
use Switch;

use Data::Dumper;
use LWP::Simple qw();
use Data::OpenGraph;
use HTML::HTML5::Microdata::Parser;
use HTML::Microdata;
use URI;
use RDF::Query;
use YAML qw();
use DateTime::Format::ISO8601;
use DateTime::Format::W3CDTF;
use DateTime::Format::HTTP;
use IO::Handle;
use Scalar::Util qw(reftype);
use Data::DPath 'dpath';

use Carp;
local $SIG{__WARN__} = sub { print( Carp::longmess (shift) ); };
#local $SIG{__DIE__} = sub { print( Carp::longmess (shift) ); };

STDOUT->binmode(":utf8");
STDERR->binmode(":utf8");

my $ua = LWP::UserAgent->new;
$ua->timeout(30);
$ua->agent('Mozilla/5.0');
my $response = $ua->get($ARGV[0]);
my $htmldoc;
if ($response->is_success) {
    $htmldoc = $response->decoded_content;
}
else {
    die $response->status_line;
}

my $og = Data::OpenGraph->parse_string($htmldoc);

my %entry = ();

sub test {
    my $x = $_[0];
    return defined ($x)
        && ((ref $x ne ''
             && ((reftype($x) eq 'ARRAY'
                  && scalar @$x)
                 || (reftype($x) eq 'HASH'
                     && scalar keys %$x)))
            || length ($x));
}


sub read_og_array {
    my ($og, $prop) = @_;
    my $prop_value = $og->property($prop);
    my @arr;
    if (test($prop_value)) {
        if (ref $prop_value ne ''
            && reftype($prop_value) eq 'ARRAY') {
            @arr = @{$prop_value};
        }
        else {
            @arr = ();
            @arr[0] = $prop_value;
        }
    }
    return @arr;
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


sub parse_author {
    my $text = $_[0];
    my $author = {};

    if ($text =~ /^\s*([^,]+)\s*,\s*(.*\S)\s*$/) {
        my $family = $1;
        my $given = $2;
        $author->{'family'} = $family;
        $author->{'given'} = $given;
    }
    elsif ($text =~ /^\s*((?:\S+\s+|\S+)+)\s+(\S+)\s*$/) {
        my $family = $2;
        my $given = $1;
        $author->{'family'} = $family;
        $author->{'given'} = $given;
    }
    else {
        $author->{'family'} = $text;
    }

    return $author;
}


my $title = $og->property('title');
if (test($title)) {
    $entry{'title'} = $title;
}

my $url = $og->property('url');
if (test($url)) {
    $entry{'URL'} = $url;
}
else {
    $entry{'URL'} = $ARGV[0];
}

my $publisher = $og->property('site_name');
if (test($publisher)) {
    $entry{'publisher'} = $publisher;
}

my $og_type = $og->property('_basictype');
if (test($og_type)) {
    my $type;
    switch ($og_type) {
        case "article" { $type = "article"; }
        case "book" { $type = "book"; }
        case "website" { $type = "website"; }
        else { $type = "website"; }
    }
    $entry{'type'} = $type;
}
else {
    Carp::carp("og:type attribute is missing.");
    $entry{'type'} = "website";
}

my $id = undef;

if ($og_type) {
    my @creators = read_og_array ($og, "$og_type:author");
    #print STDERR "creators: ", Dumper(\@creators), "\n";
    if (scalar @creators) {
        foreach my $creator (@creators) {
            #print STDERR "creator: >$creator<\n";
            my $creator_text = $creator;
            my $author = parse_author($creator_text);
            if (! $id) {
                $id = $author->{'family'};
                $id =~ s/\W//g;
                $id = lc $id;
            }

            push @{$entry{'author'}}, $author;
        }
        $entry{'id'} = $id;
    }

    my $og_issued_date_str;

    switch ($og_type) {
        case "article" {
            $og_issued_date_str = $og->property("$og_type:published_time"); }
        case "book" {
            $og_issued_date_str = $og->property("$og_type:release_date"); }
    }

    #print STDERR "published time: ", $og_issued_date_str // "(undef)", "\n";
    if (test($og_issued_date_str)) {
        my $date = DateTime::Format::ISO8601->parse_datetime($og_issued_date_str);
        my $year = $date->year;

        $entry{'issued'} = date_conversion $date;

        if (exists $entry{'id'} && $year) {
            $entry{'id'} .= $year;
        }
    }

    if ($og_type eq 'book'
        && test($og->property("$og_type:isbn"))) {
        $entry{'ISBN'} = $og->property("$og_type:isbn");
    }

    if (! test($publisher)
        && test($og->property("$og_type:publisher"))) {
        $publisher = $og->property("$og_type:publisher");
        $entry{'publisher'} = $publisher;
    }

    my @og_tags = read_og_array ($og, "$og_type:tag");
    #print STDERR "tags: ", Dumper($og->property("$og_type:tag")), "\n";
    #print STDERR "tags: ", Dumper(\@og_tags), "\n";
    if (scalar @og_tags) {
        $entry{'keyword'} = join ", ", @og_tags;
    }

} # $og_type

my $microdata = HTML::Microdata->extract($htmldoc, base => $ARGV[0]);
my $items = $microdata->items;
print STDERR "microdata as JSON:\n", Dumper($items), "\n";

my @md_authors = dpath('//author/*')->match($items);
print STDERR "microdata authors:\n", Dumper(@md_authors), "\n";
if (! test($entry{'author'})) {
    if (test(\@md_authors)) {
        foreach my $md_author (@md_authors) {
            if (exists $md_author->{'type'}
                && $md_author->{'type'} eq 'http://schema.org/Person') {
                my @authors = dpath('/properties/name/*[0]')->match($md_author);
                #print STDERR "author: ", Dumper(@authors), "\n";

                my $author = parse_author($authors[0]);
                if (! $id) {
                    $id = $author->{'family'};
                    $id =~ s/\W//g;
                    $id = lc $id;
                }
                push @{$entry{'author'}}, $author;
            }
            else {
                print STDERR ("Found author but not type http://schema.org/Person:\n",
                              Dumper($md_author), "\n");
            }
        }
    }
}

my @md_articles = dpath('//*/[key eq "type" && (value eq "http://schema.org/Article" || value eq "http://schema.org/NewsArticle")]/..')->match($items);

print STDERR "article entry:\n", Dumper(@md_articles), "\n";
if (! test($entry{'issued'})
    && test(\@md_articles)
    && test($md_articles[0]{'properties'}{'datePublished'}[0])) {
    my $date = DateTime::Format::ISO8601->parse_datetime(
        $md_articles[0]{'properties'}{'datePublished'}[0]);
    $entry{'issued'} = date_conversion($date);
}

if (0) {
my $microdata = HTML::HTML5::Microdata::Parser->new (
    $htmldoc, $ARGV[0],
    {
        alt_stylesheet => 1,
        auto_config => 1,
        mhe_lang => 1,
        #tdb_service => 1,
        xhtml_meta => 1,
        xhtml_rel => 1,
        xhtml_cite => 1,
        xhtml_time => 1,
        xhtml_title => 1,
        xml_lang => 1
    });
print STDERR "microdata->graph:\n", Dumper($microdata->graph), "\n";

my $query = RDF::Query->new(<<'SPARQL');
PREFIX schema: <http://schema.org/>
SELECT *
WHERE {
   ?author a schema:Person .
}
SPARQL

my $people = $query->execute($microdata->graph);
#print STDERR "authors from RDF:\n", Dumper($people), "\n";
while (my $person = $people->next) {
    print STDERR "people: ", $person, "\n";
}
}

my $html_headers = HTTP::Headers->new;
my $headers_parser = HTML::HeadParser->new($html_headers);
$headers_parser->parse($htmldoc);

if (! exists $entry{'author'}
    && test($html_headers->header('X-Meta-Author'))) {
    my $author = parse_author($html_headers->header('X-Meta-Author'));
    push @{$entry{'author'}}, $author;
}

my $html_meta_date_str = $html_headers->header('X-Meta-Date');
if (! exists $entry{'issued'}
    && test($html_meta_date_str)) {
    #print STDERR "date: >", $html_meta_date_str, "<\n";

    my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
    $entry{'issued'} = date_conversion $date;
}

$html_meta_date_str = $html_headers->header('X-Meta-Created');
if (! exists $entry{'issued'}
    && test($html_meta_date_str)) {
    #print STDERR "date: >", $html_meta_date_str, "<\n";

    my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
    $entry{'issued'} = date_conversion $date;
}

my $html_meta_keywords = $html_headers->header('X-Meta-Keywords');
if (! exists $entry{'keyword'}
    && test($html_meta_keywords)) {
    $html_meta_keywords =~ s/(\s)\s*/$1/g;
    $html_meta_keywords =~ s/^\s+//g;
    $html_meta_keywords =~ s/\s+$//g;
    $entry{'keyword'} = $html_meta_keywords;
}

$entry{'accessed'} = date_conversion(DateTime->today());

print "\n", YAML::Dump([\%entry]), "\n...\n";
