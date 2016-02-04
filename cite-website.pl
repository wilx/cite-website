#! env perl

use v5.16;
use strict;
use warnings;
use criticism;
use experimental 'switch';

use Data::Dumper;
use LWP::Simple qw();
use Data::OpenGraph;
use HTML::Microdata;
use HTML::TreeBuilder::XPath;
use URI;
use RDF::Query;
use YAML qw();
use JSON qw();
use DateTime::Format::ISO8601;
use DateTime::Format::W3CDTF;
use DateTime::Format::HTTP;
use DateTime::Format::CLDR;
use DateTime::Format::Epoch;
use IO::Handle;
use Scalar::Util qw(reftype);
use String::Util qw(trim);
use Data::DPath 'dpath';
use TryCatch;

use Carp;
local $SIG{__WARN__} = sub { print( Carp::longmess (shift) ); };
#local $SIG{__DIE__} = sub { print( Carp::longmess (shift) ); };

STDOUT->binmode(":utf8");
STDERR->binmode(":utf8");

my $ua = LWP::UserAgent->new;
$ua->timeout(30);
# Fake user agent identification is necessary. Some webs simply do not
# respond if they think this is some kind of crawler they do not like.
$ua->agent('Mozilla/5.0 (Windows NT 6.1; WOW64; rv:40.0) Gecko/20100101 Firefox/40.1');
my $response = $ua->get($ARGV[0]);
my $htmldoc;
if ($response->is_success) {
    $htmldoc = $response->decoded_content;
}
else {
    die $response->status_line;
}

# HTML headers parsing.

my $html_headers = HTTP::Headers->new;
my $headers_parser = HTML::HeadParser->new($html_headers);
$headers_parser->parse($htmldoc);

# Open Graph parsing.

my $og = Data::OpenGraph->parse_string($htmldoc);
#print STDERR "og:\n", Dumper($og->{properties}), "\n";
if (test($og)) {
    print STDERR "It looks like we have some Open Graph data.\n";
}

# Microdata parsing.

my $microdata = HTML::Microdata->extract($htmldoc, base => $ARGV[0]);
my $items = $microdata->items;
#print STDERR "microdata as JSON:\n", Dumper($items), "\n";
if (test($items)) {
    print STDERR "It looks like we have some microdata in HTML.\n";
}

# HTML as tree parsing.

my $tree = HTML::TreeBuilder::XPath->new;
$tree->parse($htmldoc);

# Microdata from parsely-page meta tag JSON content.

my $parsely_page = $html_headers->header('X-Meta-Parsely-Page');
my $parsely_page_content;
if (test($parsely_page)) {
    $parsely_page_content = JSON::decode_json($parsely_page);
    print STDERR "It looks like we have found some Parsely-Page microdata.\n";
    #print STDERR "parsely-page content:\n", Dumper($parsely_page_content), "\n";
}

# Schema.org data out of <script type="application/ld+json"> tag.

my $schema_org_ld_json;

try {
    my $ld_json = $tree->findvalue('//script[@type="application/ld+json"]/text()');
    #print STDERR "raw schema.org JSON+LD data:\n", Dumper($ld_json), "\n";
    if (test($ld_json)) {
        try {
            $schema_org_ld_json = JSON::decode_json($ld_json);
            print STDERR "schema.org JSON+LD data:\n", Dumper($schema_org_ld_json), "\n";
            if (!(test($schema_org_ld_json->{'@context'})
                  && $schema_org_ld_json->{'@context'} eq 'http://schema.org'
                  && test($schema_org_ld_json->{'@type'}))) {
                $schema_org_ld_json = undef;
            }
            else {
                print STDERR "It looks like we have some schema.org data in JSON+LD.\n";
            }
        }
        catch {};
    }
}
catch {};

# Parse language out of meta headers.

my $lang;
{
    my $keywords_lang = $tree->findvalue('//head/meta[@name="keywords"]/@lang');
    #print STDERR "keywords_lang: ", Dumper($keywords_lang), "\n";

    my $description_lang = $tree->findvalue('//head/meta[@name="description"]/@lang');
    #print STDERR "description_lang: ", Dumper($description_lang), "\n";

    my $og_locale = $og->property('locale');
    #print STDERR "og:locale: ", $og_locale // "(undef)", "\n";

    $lang = $og_locale // $keywords_lang // $description_lang;
    #print STDERR "lang: ", $lang // "(undef)", "\n";
}



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
    my ($text, $additional_name) = @_;
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

    if (test($additional_name)) {
        $author->{'given'} .= " (" . $additional_name . ")";
    }

    return $author;
}


sub date_parse {
    my $str = $_[0];

    # Some web sites (www.washingtonpost.com) fail at to provide a date that
    # can be parsed by any of of the code below by using only 3 digit time
    # zone offset: 2016-01-27T02:24-500. Fix it here.

    #print STDERR "original date: ", $str, "\n";
    $str =~ s/^(\d\d\d\d-?\d\d-?\d\dT\d\d:?\d\d[+-])(\d\d\d)$/${1}0$2/;
    #print STDERR "fixed date: ", $str, "\n";

    # Try various parsing routines.

    try {
        my $date = DateTime::Format::ISO8601->parse_datetime($str);
        return $date;
    }
    catch {};

    try {
        my $date = DateTime::Format::HTTP->parse_datetime($str);
        return $date;
    }
    catch {};

    if (test($lang)) {
        try {
            my $locale = DateTime::Locale->load($lang);
            my $cldr = DateTime::Format::CLDR->new(
                pattern => $locale->date_format_long,
                locale => $locale);

            print STDERR "CLDR pattern: ", $cldr->pattern, "\n";
            my $date = $cldr->parse_datetime($str);
            die "could not parse date $str: " . $cldr->errmsg() unless defined $date;
        }
        catch {};
    }

    # Parse POSIX seconds since epoch time stamp.
    if ($str =~ /\d{10,}/) {
        try {
            my $dt = DateTime->new( year => 1970, month => 1, day => 1 );
            my $parser = DateTime::Format::Epoch->new(
                epoch => $dt,
                unit => 'seconds',
                type => 'bigint',
                skip_leap_seconds => 1,
                start_at => 0,
                local_epoch => undef);
            my $date = $parser->parse_datetime($str);
            #print STDERR "date from epoch: ", $date, "\n";
            return $date;
        }
        catch {};
    }

    die "the date " . $str . " could not be parsed";
}


my $title = $og->property('title');
if (test($title)) {
    $entry{'title'} = $title;
}

my $description = $og->property('description');
if (test($description)) {
    $entry{'abstract'} = $description;
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
    print STDERR "It looks like we have Open Graph type ", $og_type, ".\n";
    my $type;
    given ($og_type) {
        when ("article") { $type = "article"; }
        when ("book") { $type = "book"; }
        when ("website") { $type = "webpage"; }
        default { $type = "webpage"; }
    }
    $entry{'type'} = $type;
}
else {
    print STDERR "og:type attribute is missing.\n";
    $entry{'type'} = "webpage";
}


if (test($og_type)) {
    my $og_issued_date_str;
    given ($og_type) {
        when ("article") {
            $og_issued_date_str = $og->property("$og_type:published_time");
        }
        when ("book") {
            $og_issued_date_str = $og->property("$og_type:release_date");
        }
    }

    #print STDERR "published time: ", $og_issued_date_str // "(undef)", "\n";
    if (test($og_issued_date_str)) {
        try {
            my $date = date_parse($og_issued_date_str);
            my $year = $date->year;

            $entry{'issued'} = date_conversion($date);

            if (exists $entry{'id'} && $year) {
                $entry{'id'} .= $year;
            }
        }
        catch {};
    }
}
elsif (! exists $entry{'issued'}
    || ! test($entry{'issued'})) {
    # Try article:published_time anyway. Some web sites are retarded like
    # that. We need to get it through DOM instead of Data::OpenGraph because
    # the Data::OpenGraph::Parser does not see it if og:type is not defined.

    my $published_time_str = $tree->findvalue(
        '//head/meta[@property="article:published_time"]/@content');
    if (test($published_time_str)) {
        try {
            my $date = date_parse($published_time_str);
            #print STDERR "date: ", Dumper($date), "\n";
            $entry{'issued'} = date_conversion($date);

            $og_type = 'article';
            print STDERR "setting og_type to article because article:published_time is present\n";
        }
        catch {};
    }
}

my $id = undef;

if (test($og_type)) {
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
}


# Microdata using the schema.org entities.

my @md_authors = dpath('//author/*')->match($items);
#print STDERR "microdata authors:\n", Dumper(@md_authors), "\n";
if (! test($entry{'author'})) {
    if (test(\@md_authors)) {
        print STDERR ("It looks like we have ", scalar @md_authors,
                      " schema.org authors.\n");
        foreach my $md_author (@md_authors) {
            if (ref $md_author ne ''
                && exists $md_author->{'type'}
                && $md_author->{'type'} eq 'http://schema.org/Person') {
                my @authors = dpath('/properties/name/*[0]')->match($md_author);
                if (test(@authors)) {
                    #print STDERR "author: ", Dumper(@authors), "\n";
                    my @additionalName = dpath('/properties/additionalName/*[0]')
                        ->match($md_author);

                    my $author = parse_author($authors[0], $additionalName[0]);
                    if (! test($id)) {
                        $id = $author->{'family'};
                        $id =~ s/\W//g;
                        $id = lc $id;
                    }
                    push @{$entry{'author'}}, $author;
                }
            }
            else {
                print STDERR "Found author but not type http://schema.org/Person: ",
                              $md_author, "\n";
            }
        }
    }
}

# Open Graph author.

if (! test($entry{'author'})
    && test($og_type)) {
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
}

my @md_articles = dpath('//*/[key eq "type"'
                        . ' && (value eq "http://schema.org/Article"'
                        . '     || value eq "http://schema.org/NewsArticle"'
                        . '     || value eq "http://schema.org/VideoObject")'
                        . '     || value eq "http://schema.org/BlogPosting"]/..')
    ->match($items);
if (test(@md_articles)) {
    print STDERR "It looks like we have an instance of schema.org article.\n";
}

print STDERR "article entry:\n", Dumper(@md_articles), "\n";
if (! test($entry{'issued'})
    && test(\@md_articles)
    && test($md_articles[0]{'properties'}{'datePublished'}[0])) {
    try {
        my $date = date_parse(
            $md_articles[0]{'properties'}{'datePublished'}[0]);
        $entry{'issued'} = date_conversion($date);
    }
    catch {};
}

if (! test($entry{'abstract'})
    && test(\@md_articles)
    && test($md_articles[0]{'properties'}{'description'}[0])) {
    $entry{'abstract'} = $md_articles[0]{'properties'}{'description'}[0];
}

# Microdata from parsely-page meta tag JSON content.

if (! test($entry{'author'})
    && test($parsely_page_content)
    && test($parsely_page_content->{'authors'})) {
    if ((ref $parsely_page_content->{'authors'} // '') eq 'ARRAY') {
        foreach my $author_str (@{$parsely_page_content->{'authors'}}) {
            my $author = parse_author($author_str);
            push @{$entry{'author'}}, $author;
        }
    }
    else {
        my $author = parse_author($parsely_page_content->{'authors'});
        push @{$entry{'author'}}, $author;
    }
}

# Schema.org microdata in JSON+LD in <script type="application/ld+json">.

if (! test($entry{'issued'})
    && test($schema_org_ld_json->{'dateCreated'})) {

    try {
        my $date = date_parse($schema_org_ld_json->{'dateCreated'});
        $entry{'issued'} = date_conversion($date);
    }
    catch {};
}

# HTML headers parsing.

if (! exists $entry{'author'}
    && test($html_headers->header('X-Meta-Author'))) {
    my $author = parse_author($html_headers->header('X-Meta-Author'));
    push @{$entry{'author'}}, $author;
}

my $html_meta_date_str = $html_headers->header('X-Meta-Date');
if (! exists $entry{'issued'}
    && test($html_meta_date_str)) {
    #print STDERR "date: >", $html_meta_date_str, "<\n";

    try {
        my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
        $entry{'issued'} = date_conversion($date);
    }
    catch {};
}

$html_meta_date_str = $html_headers->header('X-Meta-Created');
if (! exists $entry{'issued'}
    && test($html_meta_date_str)) {
    #print STDERR "date: >", $html_meta_date_str, "<\n";

    try {
        my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
        $entry{'issued'} = date_conversion($date);
    }
    catch {};
}

$html_meta_date_str = $tree->findvalue(
    '//head/meta[lower-case(@property)="published-date"]/@content');
if (! exists $entry{'issued'}
    && test($html_meta_date_str)) {
    #print STDERR "date: >", $html_meta_date_str, "<\n";

    try {
        my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
        $entry{'issued'} = date_conversion($date);
    }
    catch {};
}

my $html_meta_keywords = $html_headers->header('X-Meta-Keywords');
if (! exists $entry{'keyword'}
    && test($html_meta_keywords)) {
    trim($html_meta_keywords);
    $html_meta_keywords =~ s/(\s)\s*/$1/g;
    $entry{'keyword'} = $html_meta_keywords;
}

if (! test($entry{'abstract'})
    && test($html_headers->header('X-Meta-Description'))) {
    $entry{'abstract'} = trim($html_headers->header('X-Meta-Description'));
}


$entry{'accessed'} = date_conversion(DateTime->today());

print "\n", YAML::Dump([\%entry]), "\n...\n";
