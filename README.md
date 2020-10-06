# Ruql::Canvas

This formatter requires [ruql](https://github.com/saasbook/ruql) and
allos uploading RuQL quizzes into the Canvas LMS using its REST API.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ruql-canvas'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install ruql-canvas

## Usage

Prior to processing a quiz file, you'll need to create a simple `.yml`
file containing information about connecting to your Canvas instance's
API endpoint.  Say `ruql canvas -h` for help on the file contents
or take a look at `config.yml.sample`.

The file also lets you specify all the features of a Canvas quiz, such
as start time, whether to show one question at a time, etc.  Of course
you can change these manually after the quiz is uploaded.

If you specify an existing quiz ID, the existing quiz will be 
truncated (all questions deleted)  and its contents replaced with the one you're processing.
This is useful for modifying a quiz "in place" when external links to
the quiz ID already exist.

Quiz time limits are computed by the `ruql` gem itself (`ruql -h` for info)
but can be overridden in the `.yml` file.

If you turn on verbose mode (`--verbose` or `-V`) when running `ruql`,
you can see the REST requests being made against Canvas.

## Development/Contributing

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/ruql-canvas. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

Everyone interacting in the Ruql::Canvas project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/ruql-canvas/blob/master/CODE_OF_CONDUCT.md).
