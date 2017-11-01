#! env perl

#no warnings qw(experimental::signatures);

package RefRec;

use v5.20;
use strict;
use warnings;
use criticism;

use Moose;
use namespace::autoclean;
use MooseX::StrictConstructor;

has 'id' => (is => 'rw', isa => 'Maybe[Str]');
has 'title' => (is => 'rw', isa => 'Maybe[Str]');
has 'type' => (is => 'rw', isa => 'Maybe[Str]');
has 'author' => (is => 'rw', isa => 'Maybe[ArrayRef[HashRef[Str]]]',
    default => sub { return []; });
has 'abstract' => (is => 'rw', isa => 'Maybe[Str]');
has 'keyword' => (is => 'rw', isa => 'Maybe[Str]');
has 'container_title' => (is => 'rw', isa => 'Maybe[Str]');
has 'collection_title' => (is => 'rw', isa => 'Maybe[Str]');
has 'publisher' => (is => 'rw', isa => 'Maybe[Str]');
has 'publisher_place' => (is => 'rw', isa => 'Maybe[Str]');
has 'volume' => (is => 'rw', isa => 'Maybe[Str]');
has 'issue' => (is => 'rw', isa => 'Maybe[Str]');
has 'page' => (is => 'rw', isa => 'Maybe[Str]');
has 'issued' => (is => 'rw', isa => 'Maybe[HashRef|ArrayRef]',
                 default => undef );
has 'accessed' => (is => 'rw', isa => 'Maybe[HashRef|ArrayRef]',
                   default => undef );
has 'ISBN' => (is => 'rw', isa => 'Maybe[Str]');
has 'ISSN' => (is => 'rw', isa => 'Maybe[Str]');
has 'URL' => (is => 'rw', isa => 'Maybe[Str]');
has 'DOI' => (is => 'rw', isa => 'Maybe[Str]');

no Moose;
__PACKAGE__->meta->make_immutable;
1;


package main;

use v5.20;
use strict;
use warnings;
use criticism;
## no critic (ProhibitSubroutinePrototypes)
use experimental 'switch';
use syntax 'try';
use feature qw(signatures);
no warnings qw(experimental::signatures);

use Data::Dumper;
use LWP::Simple qw();
use Data::OpenGraph;
use HTML::Microdata;
use HTML::DublinCore;
use HTML::TreeBuilder::XPath;
use HTML::Entities;
use HTML::HeadParser;
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
use Encode;

use Carp;
local $SIG{__WARN__} = sub { print( Carp::longmess (shift) ); };
#local $SIG{__DIE__} = sub { print( Carp::longmess (shift) ); };

STDOUT->binmode(":utf8");
STDERR->binmode(":utf8");

my $ua = LWP::UserAgent->new(keep_alive => 10);
$ua->show_progress(1);
$ua->max_redirect(16);
push @{ $ua->requests_redirectable }, 'POST';
$ua->cookie_jar({});
$ua->timeout(30);
# Fake user agent identification is necessary. Some webs simply do not
# respond if they think this is some kind of crawler they do not like.
$ua->agent('Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:54.0) Gecko/20100101 Firefox/54.0');
my $response = $ua->get($ARGV[0]);
my $htmldoc;
if ($response->is_success) {
    $htmldoc = $response->decoded_content(raise_error => 1);
}
else {
    #print STDERR "resp: ", Dumper($response), "\n";
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

my ($microdata, $items);
try {
    $microdata = HTML::Microdata->extract($htmldoc, base => $ARGV[0],
                                          libxml => 0);
    $items = $microdata->items;
}
catch {};
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
    $parsely_page_content = JSON::decode_json(encode("UTF-8", $parsely_page));
    print STDERR "It looks like we have found some Parsely-Page microdata.\n";
    #print STDERR "parsely-page content:\n", Dumper($parsely_page_content), "\n";
}

# Schema.org data out of <script type="application/ld+json"> tag.

my @schema_org_ld_json = ();

try {
    my @ld_json = $tree->findvalues('//script[@type="application/ld+json"]/text()');
    foreach my $ld_json (@ld_json) {
        try {
            my $schema_org_ld_json = JSON::decode_json(encode("UTF-8", $ld_json));
            #print STDERR "schema.org JSON+LD data:\n", Dumper($schema_org_ld_json), "\n";
            if (test($schema_org_ld_json)
                && test($schema_org_ld_json->{'@context'})
                && $schema_org_ld_json->{'@context'} =~ m,^https?://schema\.org/?$,i
                && test($schema_org_ld_json->{'@type'})) {

                push @schema_org_ld_json, $schema_org_ld_json;
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
    my $html_lang = $tree->findvalue('/html/@lang');
    my $html_xml_lang = $tree->findvalue('/html/@xml:lang');
    #print STDERR "xml:lang: ", $html_xml_lang, "\n";

    my $keywords_lang = $tree->findvalue('//head/meta[@name="keywords"]/@lang');
    #print STDERR "keywords_lang: ", Dumper($keywords_lang), "\n";

    my $description_lang = $tree->findvalue('//head/meta[@name="description"]/@lang');
    #print STDERR "description_lang: ", Dumper($description_lang), "\n";

    my $og_locale = $og->property('locale');
    #print STDERR "og:locale: ", $og_locale // "(undef)", "\n";

    $lang = $og_locale // $html_lang // $html_xml_lang // $keywords_lang
        // $description_lang;
    #print STDERR "lang: ", $lang // "(undef)", "\n";
}

# Parse DublinCore meta headers.

my $dc;
try {
    $dc = HTML::DublinCore->new($htmldoc);
    #print STDERR "DublinCore:\n", Dumper($dc), "\n";
} catch {};


# Fill in %entry.

sub test {
    my $x = $_[0];
    return (defined ($x)
            && ((ref $x ne ''
                 && ((reftype($x) eq 'ARRAY'
                      && scalar @$x)
                     || (reftype($x) eq 'HASH'
                         && scalar keys %$x)))
                || (ref($x) eq ''
                    && length($x) != 0)))
        ? 1 : undef;
}

sub choose {
    my @values = @_;
    #print STDERR "choose(", Dumper(\@values), ")\n";
    foreach my $val (@values) {
        if (test($val)) {
            #print STDERR "Choosing ", Dumper($val), "\n";
            return $val;
        }
    }

    #print STDERR "Not choosing any value, returning undef.\n";
    return;
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


sub trim_multiline_string ($str) {
    $str =~ s/(?:\s*(\R)){2}\s*\R*\s*/$1$1/g;
    return trim($str);
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
    my ($str, $additional_name) = @_;
    my @authors = ();
    #print STDERR "Name: ", $str, "\n";
    # Try as if string contains multiple names separated by "and".
    my @names = split /,?\s*and\s+/, $str;
    foreach my $text (@names) {
        # Sometimes the author metadata contains a link to Facebook page or
        # similar links and hides actual author name in other metadata
        # sources. We want to avoid this.
        next if $text =~ /^https?:/;
        my $author = {};
        # Family name (comma) Given name
        if ($text =~ /^\s*([^,]+)\s*,\s*(.*\S)\s*$/) {
            #print STDERR "Family name, Given name\n";
            my $family = $1;
            my $given = $2;
            $author->{'family'} = $family;
            $author->{'given'} = $given;
        }
        elsif ($text =~ /^\s*((?:\S+\s+|\S+)+)\s+(\S+)\s*$/) {
            #print STDERR "long name\n";
            my $family = $2;
            my $given = $1;
            $author->{'family'} = $family;
            $author->{'given'} = $given;
        }
        else {
            #print STDERR "just name\n";
            $author->{'family'} = $text;
        }

        if (scalar @names == 0
            && test($additional_name)) {
            $author->{'given'} .= " (" . $additional_name . ")";
        }

        push @authors, $author;
    }

    return @authors;
}


sub remove_dupe_authors {
    my ($rec) = @_;
    my @authors = @{$rec->author};
    my %seen = ();
    my @deduped_authors = grep {
        not $seen{$_->{'family'}}{$_->{'given'} // ''}++; } @authors;
    $rec->author([@deduped_authors]);
}


sub date_parse_using_cldr ($locale, $format, $str) {
    my $cldr = DateTime::Format::CLDR->new(
        pattern => $locale->$format,
        locale => $locale);
    #print STDERR "CLDR pattern: ", $cldr->pattern, " for locale ", $locale->name, "\n";
    my $date = $cldr->parse_datetime($str);
    die "could not parse date " . $str . " with CLDR " . $cldr->pattern . ": "
        . $cldr->errmsg() unless defined $date;
    return $date;
}


sub date_parse {
    my $str = $_[0];
    my $orig = $str;
    print STDERR "Original date: ", $orig, "\n";

    # Trim it.
    $str = trim($str);

    # Some web sites (www.washingtonpost.com) fail at to provide a date that
    # can be parsed by any of of the code below by using only 3 digit time
    # zone offset: 2016-01-27T02:24-500. Fix it here.

    if ($str =~ s/^(\d\d\d\d-?\d\d-?\d\dT\d\d:?\d\d[+-])(\d\d\d)$/${1}0$2/) {
        print STDERR "Adding missing zero to time zone offset in date: ", $str, "\n";
    }

    # Different sites (www.theglobeandmail.com) provide dates with time zone
    # added as abbreviation, e.g., EDT in 2017-06-15T21:06:21EDT. None of the
    # so far employed modules want to parse that and converting the EDT
    # string into actual offset is not trivial. So we remove the time zone
    # here as it is not terribly important.

    if ($str =~ s/^(.+)([a-z]{3}(?:[a-z]{0,2}\d?)?)$/$1/i) {
        print STDERR "Stripping time zone abbreviation from date: ", $str, "\n";
    }
    #print STDERR "fixed date: ", $str, "\n";

    # Try various parsing routines.

    try {
        my $date = DateTime::Format::ISO8601->parse_datetime($str);
        print STDERR "Date ", $str, " looks like ISO 8601 date.\n";
        return $date;
    }
    catch {
        print STDERR "Hmm, ", $str, " does not seem to be ISO 8601 date.\n";
    };

    try {
        my $date = DateTime::Format::HTTP->parse_datetime($str);
        print STDERR "Date ", $str, " looks like HTTP formatted date.\n";
        return $date;
    }
    catch {
        print STDERR "Hmm, ", $str, " does not seem to be HTTP formatted date.\n";
    };

    if (test($lang)) {
        try {
            my $locale = DateTime::Locale->load($lang);
            #print STDERR "locale: ", Dumper($locale), "\n";

            try {
                my $date = date_parse_using_cldr($locale, 'date_format_full', $str);
                print STDERR "Date ", $str, " looks like full date in ", $locale->name,
                    " locale\n";
                return $date;
            }
            catch {};

            try {
                my $date = date_parse_using_cldr($locale, 'date_format_long', $str);
                print STDERR "Date ", $str, " looks like long date in ", $locale->name,
                    " locale\n";
                return $date;
            }
            catch {};

            try {
                my $date = date_parse_using_cldr($locale, 'date_format_medium', $str);
                print STDERR "Date ", $str, " looks like medium date in ", $locale->name,
                    " locale\n";
                return $date;
            }
            catch {};

            try {
                my $date = date_parse_using_cldr($locale, 'date_format_short', $str);
                print STDERR "Date ", $str, " looks like short date in ", $locale->name,
                    " locale\n";
                return $date;
            }
            catch {};
        }
        catch {
            print STDERR "Failed to load \"", $lang, "\" locale\n";
        };
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
            print STDERR "Date ", $str, " looks like seconds since UNIX epoch\n";
            return $date;
        }
        catch {};
    }

    die "the date " . $str . " could not be parsed";
}

# Build RefRec out of OpenGraph data.

sub processOpenGraph ($og) {
    my $ogRec = RefRec->new;

    my $title = $og->property('title');
    if (test($title)) {
        $ogRec->title(decode_entities($title));
    }

    my $description = $og->property('description');
    if (test($description)) {
        $ogRec->abstract(trim_multiline_string(decode_entities($description)));
    }

    my $url = $og->property('url');
    if (test($url)) {
        $ogRec->URL($url);
    }

    my $publisher = $og->property('site_name');
    if (test($publisher)) {
        $ogRec->publisher(decode_entities($publisher));
    }

    my $og_type = $og->property('_basictype');
    if (test($og_type)) {
        print STDERR "It looks like we have Open Graph type ", $og_type, ".\n";
        my $type;
        given ($og_type) {
            when ("article") { $type = "article"; }
            when ("book") { $type = "book"; }
            when ("website") { $type = "webpage"; }
            when ("video") { $type = "video";}
            default { $type = "webpage"; }
        }
        $ogRec->type($type);
    }
    else {
        print STDERR "og:type attribute is missing.\n";
        $ogRec->type("webpage");
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

                $ogRec->issued(date_conversion($date));

                # TODO: Add 'id' generation for final reference record.
                #if (exists $entry{'id'} && $year) {
                #    $entry{'id'} .= $year;
                #}
            }
            catch {};
        }
    }
    elsif (! test($ogRec->issued)) {
        # Try article:published_time anyway. Some web sites are retarded like
        # that. We need to get it through DOM instead of Data::OpenGraph because
        # the Data::OpenGraph::Parser does not see it if og:type is not defined.

        my $published_time_str = $tree->findvalue(
            '//head/meta[@property="article:published_time"]/@content');
        if (test($published_time_str)) {
            try {
                my $date = date_parse($published_time_str);
                #print STDERR "date: ", Dumper($date), "\n";
                $ogRec->issued(date_conversion($date));

                $ogRec->type('article');
                print STDERR "setting og_type to article because article:published_time is present\n";
            }
            catch {};
        }
    }

    #my $id = undef;

    if (test($og_type)) {
        if ($og_type eq 'book'
            && test($og->property("$og_type:isbn"))) {
            $ogRec->ISBN($og->property("$og_type:isbn"));
        }

        if (! test($publisher)
            && test($og->property("$og_type:publisher"))) {
            $publisher = $og->property("$og_type:publisher");
            $ogRec->publisher($publisher);
        }

        my @og_tags = read_og_array ($og, "$og_type:tag");
        #print STDERR "tags: ", Dumper($og->property("$og_type:tag")), "\n";
        #print STDERR "tags: ", Dumper(\@og_tags), "\n";
        if (scalar @og_tags) {
            $ogRec->keyword(join ", ", @og_tags);
        }
    }

    # Author.

    if (test($og_type)) {
        my @creators = read_og_array ($og, "$og_type:author");
        #print STDERR "creators: ", Dumper(\@creators), "\n";
        if (scalar @creators) {
            foreach my $creator (@creators) {
                #print STDERR "creator: >$creator<\n";
                my $creator_text = $creator;
                push @{$ogRec->author}, parse_author($creator_text);
            }
            remove_dupe_authors($ogRec);
        }
    }

    return $ogRec;
}

my $ogRec = RefRec->new;
if (test($og)) {
    $ogRec = processOpenGraph($og);
}


# Microdata using the schema.org entities.

sub prep_single_schema_org_url_re ($entity) {
    return qr,(?i:^https?://schema\.org/\Q$entity\E/?$),;
}

sub prep_schema_org_re {
    my @entities = @_;
    @entities = map { my $e = $_; prep_single_schema_org_url_re($e); } @entities;
    my $re;
    for my $part (@entities) {
        if (!defined $re) {
            $re = $part;
        }
        else {
            $re = $part . '|' . $re;
        }
    }
    #print STDERR "built re for some schema.org entities: ", $re, "\n";
    return $re;
}

sub prep_schema_org_type_re_condition {
    my @entities = @_;
    my $value_expression = prep_schema_org_re(@entities);
    $value_expression =~ s,/,\\/,g;
    my $condition = 'key eq "type" && value =~ /' . $value_expression . '/';
    return $condition;
}

sub processSchemaOrg($item) {
    my $mdRec = RefRec->new;

    # Sometimes the top level element is missing. Inject CreativeWork and
    # hope for the best.

    if (exists $item->{'properties'}
        && ! exists $item->{'type'}) {
        my $creative_work = 'http://schema.org/CreativeWork';
        print STDERR "This schema.org entity is missing type, let's inject ",
            $creative_work, "\n";
        $item->{'type'} = $creative_work;
    }

    my @md_authors = dpath('//author/*')->match($item);
    if (!test(\@md_authors)) {
        # No actual authors have been found. Look for any Person entities.
        @md_authors = dpath('//*['
                            . prep_schema_org_type_re_condition("Person")
                            . "]/..")->match($item);
    }
    #print STDERR "microdata authors:\n", Dumper(@md_authors), "\n";

    if (test(\@md_authors)) {
        print STDERR ("It looks like we have ", scalar @md_authors,
                      " schema.org authors.\n");
        foreach my $md_author (@md_authors) {
            print STDERR "md_author: ", Dumper($md_author), "\n";
            if (ref $md_author ne ''
                && exists $md_author->{'type'}
                && $md_author->{'type'} =~ prep_schema_org_re('Person')) {
                my @authors = dpath('/properties/name/*[0]')->match($md_author);
                if (test(@authors)) {
                    #print STDERR "author: ", Dumper(@authors), "\n";
                    my @additionalName = dpath('/properties/additionalName/*[0]')
                        ->match($md_author);
                    push @{$mdRec->author}, parse_author($authors[0], $additionalName[0]);
                }
            }
            elsif (ref $md_author eq ''
                   && test($md_author)) {
                push @{$mdRec->author}, parse_author($md_author);
            }
            else {
                print STDERR "Could not decode author data: ", $md_author, "\n";
            }
        }
        remove_dupe_authors($mdRec);
    }

    my @known_entities = ("Article",
                          "Book",
                          "CreativeWork",
                          "NewsArticle",
                          "VideoObject",
                          "ScholarlyArticle",
                          "BlogPosting",
                          "WebPage",
                          "MediaObject");

    my $dpath_query = ('//*/['
                       . prep_schema_org_type_re_condition(@known_entities)
                       . ']/..');
    #print STDERR "dpath query: ", $dpath_query, "\n";
    my @md_articles = dpath($dpath_query)->match($item);
    print STDERR "md_articles: ", Dumper(\@md_articles), "\n";
    if (test(\@md_articles)) {
        my @types = map { $_->{'type'} } @md_articles;
        print STDERR "It looks like we have instance(s) of ",
            (join ", ", @types), "\n";
    }
    else {
        print STDERR "We did not find any known to us schema.org entity for content.\n";
        return $mdRec;
    }

    print STDERR "article entry:\n", Dumper(@md_articles), "\n";

    if (test($md_articles[0]{'properties'}{'datePublished'}[0])) {
        try {
            my $date = date_parse(
                $md_articles[0]{'properties'}{'datePublished'}[0]);
            $mdRec->issued(date_conversion($date));
        }
        catch {};
    }
    elsif (test($md_articles[0]{'properties'}{'dateCreated'}[0])) {
        try {
            my $date = date_parse(
                $md_articles[0]{'properties'}{'dateCreated'}[0]);
            $mdRec->issued(date_conversion($date));
        }
        catch {};
    }
    elsif (test($md_articles[0]{'properties'}{'uploadDate'}[0])) {
        try {
            my $date = date_parse(
                $md_articles[0]{'properties'}{'uploadDate'}[0]);
            $mdRec->issued(date_conversion($date));
        }
        catch {};
    }

    my @publisher = dpath(
        '/properties/publisher/*/['
        . prep_schema_org_type_re_condition("Organization")
        . ']/../properties/name')
        ->match($md_articles[0]);
    if (test(\@publisher)) {
        $mdRec->publisher((join ", ", $publisher[0][0]));
    } elsif (test($md_articles[0]{'properties'}{'publisher'}[0])) {
        my $publisher = $md_articles[0]{'properties'}{'publisher'}[0];
        if (reftype($publisher) eq '') {
            $mdRec->publisher($publisher);
        }
        else {
            print STDERR "Publisher is in unrecognized data structure: ",
                Dumper($publisher), "\n";
        }
    }

    my $title = $md_articles[0]{'properties'}{'headline'}[0]
        // $md_articles[0]{'properties'}{'name'}[0];
    if (test($title)) {
        $mdRec->title($title);
    }

    if (test($md_articles[0]{'properties'}{'isbn'}[0])) {
        $mdRec->ISBN($md_articles[0]{'properties'}{'isbn'}[0]);
    }

    if (test($md_articles[0]{'properties'}{'description'}[0])) {
        $mdRec->abstract(
            trim_multiline_string(
                (join "\n", @{$md_articles[0]{'properties'}{'description'}})));
    }

    if (test($md_articles[0]{'properties'}{'keywords'})) {
        $mdRec->keyword(join ", ", @{$md_articles[0]{'properties'}{'keywords'}});
    }

    my @ispartof = dpath(
        '/properties/isPartOf/*/'
        . '['
        . prep_schema_org_type_re_condition("PublicationVolume")
        . ']/'
        . '../properties')
        ->match($md_articles[0]);
    #print STDERR "ispartof:\n", Dumper(\@ispartof), "\n";
    if (test(@ispartof)) {
        print STDERR "It looks like we have isPartOf/PublicationVolume in article.\n";


        my @vol = dpath('/volumeNumber/*[0]')->match($ispartof[0]);
        #print STDERR "volume:\n", Dumper(\@vol), "\n";
        if (test(\@vol)) {
            $mdRec->volume($vol[0]);
        }

        my @cont = dpath('/isPartOf/*[0]/*/'
                         . '['
                         . prep_schema_org_type_re_condition('Periodical')
                         . ']/'
                         . '../properties/name/*[0]')->match($ispartof[0]);
        if (test (\@cont)) {
            $mdRec->container_title($cont[0]);
        }

    }

    my $type = $md_articles[0]{'type'};
    if ($type =~ prep_single_schema_org_url_re('ScholarlyArticle')) {
        if (test($mdRec->container_title)) {
            $mdRec->type('article-journal');
        }
        else {
            $mdRec->type('article');
        }
    } elsif ($type =~ prep_single_schema_org_url_re('Book')) {
        $mdRec->type('book');
    }

    return $mdRec;
}

my @mdRecs = ();
for my $item (@$items) {
    if (test($item)) {
        my $mdRec = processSchemaOrg($item);
        push @mdRecs, $mdRec;
    }
}


# Microdata from parsely-page meta tag JSON content.

sub processParselyPage ($parsely_page_content) {
    my $parselyPageRec = RefRec->new;

    if (test($parsely_page_content->{'authors'})) {
        if ((ref $parsely_page_content->{'authors'} // '') eq 'ARRAY') {
            foreach my $author_str (@{$parsely_page_content->{'authors'}}) {
                push @{$parselyPageRec->author}, parse_author($author_str);
            }
        }
        else {
            push @{$parselyPageRec->author}, parse_author($parsely_page_content->{'authors'});
        }
        remove_dupe_authors($parselyPageRec);
    }

    if (test($parsely_page_content->{'title'})) {
        $parselyPageRec->title($parsely_page_content->{'title'});
    }

    if (test($parsely_page_content->{'pub_date'})) {
        try {
            my $date = date_parse($parsely_page_content->{'pub_date'});
            $parselyPageRec->issued(date_conversion($date));
        }
        catch {};
    }

    if ((ref $parsely_page_content->{'tags'} // '') eq 'ARRAY') {
        $parselyPageRec->keyword((join ", ", @{$parsely_page_content->{'tags'}}));
    }
    else {
        my $tag_str = $parsely_page_content->{'tags'};
        $parselyPageRec->keyword($tag_str);
    }

    return $parselyPageRec;
}

my $parselyPageRec = RefRec->new;
if (test($parsely_page_content)) {
    $parselyPageRec = processParselyPage($parsely_page_content);
}


# Schema.org microdata in JSON+LD in <script type="application/ld+json">.

sub scalar_to_array ($x) {
    if (ref($x) eq 'ARRAY') {
        return @{$x};
    }
    else {
        return ($x,);
    }
}

sub processSchemaOrgJsonLd ($schema_org_ld_json) {
    #print STDERR "LD+JSON: ", Dumper($schema_org_ld_json), "\n";

    my $schemaOrgJsonLd = RefRec->new;

    my $context;

    if (test($schema_org_ld_json->{'datePublished'})) {
        try {
            my $date = date_parse($schema_org_ld_json->{'datePublished'});
            $schemaOrgJsonLd->issued(date_conversion($date));
        }
        catch {};
    }
    elsif (test($schema_org_ld_json->{'dateCreated'})) {
        try {
            my $date = date_parse($schema_org_ld_json->{'dateCreated'});
            $schemaOrgJsonLd->issued(date_conversion($date));
        }
        catch {};
    }

    my $authors = choose($schema_org_ld_json->{'author'},
                         $schema_org_ld_json->{'creator'});
    if (test($authors)) {
        if ((reftype($authors) // '') eq 'HASH') {
            $authors = $authors->{'name'};
            for my $author_str (scalar_to_array($authors)) {
                push @{$schemaOrgJsonLd->author}, parse_author($author_str);
            }
        }
        else {
            for my $author_str (scalar_to_array($authors)) {
                push @{$schemaOrgJsonLd->author}, parse_author($author_str);
            }
        }
        remove_dupe_authors($schemaOrgJsonLd);
    }

    my $keywords = $schema_org_ld_json->{'keywords'};
    if (test($keywords)) {
        for my $keywords (scalar_to_array($keywords)) {
            $schemaOrgJsonLd->keyword((join ", ", $keywords));
        }
    }

    #print STDERR "Parsed Schema.org JSON+LD record: ", Dumper($schemaOrgJsonLd), "\n";

    return $schemaOrgJsonLd;
}

my @schemaOrgJsonLd = ();
foreach my $ld_json (@schema_org_ld_json) {
    my $schemaOrgJsonLd = RefRec->new;
    if (test($ld_json)) {
        try {
            push @schemaOrgJsonLd, processSchemaOrgJsonLd($ld_json);
        }
        catch {};
    }
}


# Citation HTML header meta element metadata.

sub processHtmlHeaderMetaCitation ($html_headers) {
    my $htmlMetaCitationRec = RefRec->new;

    for my $meta_name ('X-Meta-Citation-Online-Date', 'X-Meta-Citation-Date',
                       'X-Meta-Citation-Publication-Date') {
        my $citation_date_str = $html_headers->header($meta_name);
        if (test($citation_date_str)) {
            try {
                my $date = date_parse($citation_date_str);
                $htmlMetaCitationRec->issued(date_conversion($date));
            }
            catch {};
            last if test($htmlMetaCitationRec->issued);
        }
    }

    my $citation_title = $html_headers->header('X-Meta-Citation-Title');
    if (test($citation_title)) {
        $htmlMetaCitationRec->title(trim(decode_entities($citation_title)));
    }

    my @authors = $html_headers->header('X-Meta-Citation-Author');
    if (test(\@authors)) {
        for my $author_str (@authors) {
            push @{$htmlMetaCitationRec->author}, parse_author($author_str);
        }
        remove_dupe_authors($htmlMetaCitationRec);
    }

    my $pdf_url = $html_headers->header('X-Meta-Citation-Pdf-Url');
    if (test($pdf_url)) {
        $htmlMetaCitationRec->URL(trim(decode_entities($pdf_url)));
    }

    my $journal = $html_headers->header('X-Meta-Citation-Journal-Title');
    if (test($journal)) {
        #print STDERR "journal title: ", $journal, "\n";
        $htmlMetaCitationRec->container_title(trim(decode_entities($journal)));
        #print STDERR "journal title after: ", $htmlMetaCitationRec->container_title, "\n";
    }

    my $volume = $html_headers->header('X-Meta-Citation-Volume');
    if (test($volume)) {
        $htmlMetaCitationRec->volume(trim(decode_entities($volume)));
    }

    my $issue = $html_headers->header('X-Meta-Citation-Issue');
    if (test($issue)) {
        $htmlMetaCitationRec->issue(trim(decode_entities($issue)));
    }

    my $ISSN = $html_headers->header('X-Meta-Citation-ISSN');
    if (test($ISSN)) {
        $htmlMetaCitationRec->ISSN(trim(decode_entities($ISSN)));
    }

    my $first_page = trim(
        decode_entities(
            $html_headers->header('X-Meta-Citation-FirstPage') // ''));
    my $last_page = trim(
        decode_entities(
            $html_headers->header('X-Meta-Citation-LastPage') // ''));
    if (test($first_page)) {
        if (test($last_page)) {
            $htmlMetaCitationRec->page("$first_page-$last_page");
        }
        else {
            $htmlMetaCitationRec->page($first_page);
        }
    }

    my $doi = $html_headers->header('X-Meta-Citation-DOI');
    if (test($doi)) {
        $htmlMetaCitationRec->DOI(trim(decode_entities($doi)));
    }

    if (test($htmlMetaCitationRec->container_title)
        && test($htmlMetaCitationRec->volume)
        && test($htmlMetaCitationRec->issue)) {
        $htmlMetaCitationRec->type('article-journal');
    }
    else {
        $htmlMetaCitationRec->type('article');
    }

    return $htmlMetaCitationRec;
}

my $htmlMetaCitationRec = processHtmlHeaderMetaCitation($html_headers);


# Bepress Citation HTML header meta element metadata.

sub processHtmlHeaderBepressMetaCitation ($html_headers) {
    my $htmlMetaCitationRec = RefRec->new;

    my $citation_date_str = $html_headers->header('X-Meta-Bepress-Citation-Online-Date');
    if (test($citation_date_str)) {
        try {
            my $date = date_parse($citation_date_str);
            $htmlMetaCitationRec->issued(date_conversion($date));
        }
        catch {};
    }
    elsif (test($citation_date_str
                = $html_headers->header('X-Meta-Bepress-Citation-Date'))) {
        try {
            my $date = date_parse($citation_date_str);
            $htmlMetaCitationRec->issued(date_conversion($date));
        }
        catch {};
    }

    my $citation_title = $html_headers->header('X-Meta-Bepress-Citation-Title');
    if (test($citation_title)) {
        $htmlMetaCitationRec->title(trim(decode_entities($citation_title)));
    }

    my @authors = $html_headers->header('X-Meta-Bepress-Citation-Author');
    if (test(\@authors)) {
        for my $author_str (@authors) {
            push @{$htmlMetaCitationRec->author}, parse_author($author_str);
        }
        remove_dupe_authors($htmlMetaCitationRec);
    }

    my $pdf_url = $html_headers->header('X-Meta-Bepress-Citation-Pdf-Url');
    if (test($pdf_url)) {
        $htmlMetaCitationRec->URL(trim(decode_entities($pdf_url)));
    }

    my $citation_series = $html_headers->header('X-Meta-Bepress-Citation-Series-Title');
    if (test($citation_series)) {
        $htmlMetaCitationRec->collection_title(trim(decode_entities($citation_series)));
    }

    $htmlMetaCitationRec->type('article');

    return $htmlMetaCitationRec;
}

my $htmlMetaBepressCitationRec = processHtmlHeaderBepressMetaCitation($html_headers);


# DublinCore metadata.

sub processDublinCoreHtml ($dc) {
    #print STDERR "DC object:\n", Dumper($dc), "\n";

    my $dcRec = RefRec->new;

    my $title = $dc->element('Title');
    if (test($title) && test($title->content)) {
        $dcRec->title($title->content);
    }

    if (test($dc->element('Creator'))) {
        for my $author ($dc->element('Creator')) {
            push @{$dcRec->author}, parse_author($author->content);
        }
    }

    if (test($dc->element('Contributor'))) {
        for my $author ($dc->element('Contributor')) {
            push @{$dcRec->author}, parse_author($author->content);
        }
    }

    remove_dupe_authors($dcRec);

    my $date;
    if (test($date = $dc->element('Date'))
        && test($date = $date->content)) {
        $date = date_parse($date);
        $dcRec->issued(date_conversion($date));
    }

    my $identifier = $dc->element('Identifier');
    if (test($identifier) && test($identifier = $identifier->content)
        # The follwing regex is taken from SO answer
        # <https://stackoverflow.com/a/10324802/341065>.
        && $identifier =~ /\b(10[.][0-9]{4,}(?:[.][0-9]+)*\/(?:(?!["&\'<>])\S)+)\b/) {
        $dcRec->DOI($identifier);
    }
    elsif (test($identifier) && $identifier =~ /^https?/) {
        $dcRec->URL($identifier);
    }

    my $publisher = $dc->element('Publisher');
    if (test($publisher) && test($publisher = $publisher->content)) {
        $dcRec->publisher($publisher);
    }

    my $description = $dc->element('Description');
    if (test($description) && test($description = $description->content)) {
        $dcRec->abstract(trim_multiline_string($description));
    }

    #print STDERR "DublinCore metadata:\n", Dumper($dcRec), "\n";
    return $dcRec;
}

my $dcRec = RefRec->new;
if (test($dc)) {
    $dcRec = processDublinCoreHtml($dc);
}


# HTML headers parsing.

sub processHtmlHeaderMeta ($html_headers) {
    my $htmlHeaderRec = RefRec->new;

    if (test($html_headers->title)) {
        $htmlHeaderRec->title(trim($html_headers->title));
    }

    if (test($html_headers->header('X-Meta-Author'))) {
        my $author = $html_headers->header('X-Meta-Author');
        push @{$htmlHeaderRec->author}, parse_author($author);
    }
    remove_dupe_authors($htmlHeaderRec);

    my $html_meta_date_str = $html_headers->header('X-Meta-Date');
    if (test($html_meta_date_str)) {
        #print STDERR "date: >", $html_meta_date_str, "<\n";

        try {
            my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
            $htmlHeaderRec->issued(date_conversion($date));
        }
        catch {};
    }

    $html_meta_date_str = $html_headers->header('X-Meta-Created');
    if (! test($htmlHeaderRec->issued)
        && test($html_meta_date_str)) {
        #print STDERR "date: >", $html_meta_date_str, "<\n";

        try {
            my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
            $htmlHeaderRec->issued(date_conversion($date));
        }
        catch {};
    }

    $html_meta_date_str = $tree->findvalue(
        '//head/meta[lower-case(@property)="published-date"]/@content');
    if (! test($htmlHeaderRec->issued)
        && test($html_meta_date_str)) {
        #print STDERR "date: >", $html_meta_date_str, "<\n";

        try {
            my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
            $htmlHeaderRec->issued(date_conversion($date));
        }
        catch {};
    }

    my $html_meta_keywords = $html_headers->header('X-Meta-Keywords')
        // $html_headers->header('X-Meta-News-Keywords');
    if (test($html_meta_keywords)) {
        trim($html_meta_keywords);
        $html_meta_keywords =~ s/(\s)\s*/$1/g;
        $htmlHeaderRec->keyword($html_meta_keywords);
    }

    my $html_meta_description = $html_headers->header('X-Meta-Description');
    if (test($html_meta_description)) {
        $htmlHeaderRec->abstract(
            trim_multiline_string(
                choose($html_meta_description)));
    }

    return $htmlHeaderRec;
}

my $htmlHeaderRec = RefRec->new;
if (defined $html_headers) {
    $htmlHeaderRec = processHtmlHeaderMeta($html_headers);
}


sub processRelAttribute ($tree) {
    my $relRec = RefRec->new;

    my @authors = $tree->findvalues('//*[@rel="author"]/text()');
    #print STDERR "author from rel=\"author\": ", Dumper(\@authors), "\n";
    if (test(\@authors)) {
        push @{$relRec->author}, map { parse_author($_) } @authors;
    }
    remove_dupe_authors($relRec);

    my $url = choose($tree->findvalues('//head/link[@rel="shortlink"]/@href'),
                     $tree->findvalues('//head/link[@rel="canonical"]/@href'));
    if (test($url)) {
        $relRec->URL(decode_entities($url));
    }

    return $relRec;
}

my $relRec = RefRec->new;
if (defined $tree) {
    $relRec = processRelAttribute($tree);
}


sub gather_property {
    my ($property, @records) = @_;
    $property =~ y/-/_/;
    my @values = ();
    for my $record (@records) {
        push @values, $record->$property;
    }
    #print STDERR "gathered values for property \"$property\": ", Dumper(\@values), "\n";
    return @values;
}

my %entry = ();

$entry{'title'} = choose(
    gather_property(
        'title', @mdRecs, $ogRec, $dcRec, $htmlMetaCitationRec,
        @schemaOrgJsonLd, $parselyPageRec, $htmlMetaBepressCitationRec,
        $htmlHeaderRec));
$entry{'type'} = choose(
    gather_property(
        'type',
        @mdRecs, $htmlMetaCitationRec, $ogRec, @schemaOrgJsonLd,
        $parselyPageRec, $htmlMetaBepressCitationRec, $htmlHeaderRec));
$entry{'author'} = choose(
    gather_property(
        'author',
        $dcRec, $htmlMetaCitationRec, @mdRecs, @schemaOrgJsonLd, $ogRec,
        $parselyPageRec, $htmlMetaBepressCitationRec, $htmlHeaderRec, $relRec));
$entry{'accessed'} = date_conversion(DateTime->today());
$entry{'issued'} = choose(
    gather_property(
        'issued',
        $dcRec, @mdRecs, $ogRec, $htmlMetaCitationRec, @schemaOrgJsonLd,
        $parselyPageRec, $htmlMetaBepressCitationRec, $htmlHeaderRec));
$entry{'container-title'} = choose(
    gather_property(
        'container-title',
        $htmlMetaCitationRec,  @mdRecs, $ogRec, @schemaOrgJsonLd, $parselyPageRec,
        $htmlHeaderRec));
$entry{'collection-title'} = choose(
    gather_property(
        'collection-title',
        $htmlMetaCitationRec,  @mdRecs, $ogRec, @schemaOrgJsonLd, $parselyPageRec,
        $htmlMetaBepressCitationRec, $htmlHeaderRec));
$entry{'publisher'} = choose(
    gather_property(
        'publisher',
        $dcRec, @mdRecs, $ogRec, @schemaOrgJsonLd, $parselyPageRec,
        $htmlMetaBepressCitationRec, $htmlHeaderRec));
$entry{'publisher-place'} = choose(
    gather_property(
        'publisher-place',
        @mdRecs, $ogRec, @schemaOrgJsonLd, $parselyPageRec,
        $htmlMetaBepressCitationRec, $htmlHeaderRec));
$entry{'volume'} = choose(
    gather_property(
        'volume',
        @mdRecs, $htmlMetaCitationRec, $ogRec, @schemaOrgJsonLd, $parselyPageRec,
        $htmlHeaderRec));
$entry{'issue'} = choose(
    gather_property(
        'issue',
        @mdRecs, $htmlMetaCitationRec, $ogRec, @schemaOrgJsonLd, $parselyPageRec,
        $htmlHeaderRec));
$entry{'page'} = choose(
    gather_property(
        'page',
        @mdRecs, $htmlMetaCitationRec, $ogRec, @schemaOrgJsonLd, $parselyPageRec,
        $htmlHeaderRec));
$entry{'abstract'} = choose(
    gather_property(
        'abstract',
        $dcRec, @mdRecs, $ogRec, @schemaOrgJsonLd, $parselyPageRec,
        $htmlHeaderRec));
$entry{'keyword'} = choose(
    gather_property(
        'keyword',
        @mdRecs, $ogRec, @schemaOrgJsonLd, $parselyPageRec, $htmlHeaderRec));
$entry{'ISBN'} = choose(
    gather_property(
        'ISBN',
        @mdRecs, $ogRec, @schemaOrgJsonLd, $parselyPageRec, $htmlHeaderRec));
$entry{'ISSN'} = choose(
    gather_property(
        'ISSN',
        @mdRecs, $htmlMetaCitationRec, $ogRec, @schemaOrgJsonLd, $parselyPageRec,
        $htmlHeaderRec));
$entry{'DOI'} = choose(
    gather_property(
        'DOI',
        $dcRec, @mdRecs, $htmlMetaCitationRec, $ogRec, @schemaOrgJsonLd,
        $parselyPageRec, $htmlHeaderRec));
$entry{'URL'} = choose(
    gather_property(
        'URL',
        @mdRecs, $ogRec, $htmlMetaCitationRec, @schemaOrgJsonLd,
        $parselyPageRec, $htmlMetaBepressCitationRec, $htmlHeaderRec,
        $dcRec, $relRec), $ARGV[0]);

# Remove undef values from entry.
while (my ($key, $val) = each %entry) {
    delete $entry{$key} if not test($val);
}

#print STDERR "Dump: ", Dumper(\%entry), "\n";
print "\n", YAML::Dump([\%entry]), "\n...\n";
