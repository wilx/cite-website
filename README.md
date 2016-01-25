# cite-website

Simple Perl script to generate CSL YAML entry from given URL.

E.g., running `cite-website.pl 'http://www.nydailynews.com/news/national/navy-rid-gender-specific-titles-article-1.2504407'` produces the following output:

~~~{.yaml}
---
- URL: http://www.nydailynews.com/news/national/navy-rid-gender-specific-titles-article-1.2504407
  accessed:
    date-parts:
      -
        - 2016
        - 1
        - 25
  issued:
    date-parts:
      -
        - 2016
        - 1
        - 21
  keyword: 'Navy gender titles, midshipman, Navy Secretary Ray Mabu, Navy SEALS, Defense Secretary Ash Carter'
  publisher: NY Daily News
  title: 'The Navy to get rid of gender-specific titles '
  type: article

...
~~~
