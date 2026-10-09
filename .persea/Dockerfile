FROM ruby:3.1.3

WORKDIR /workspace

RUN gem install bundler -v 2.3.26

COPY .ruby-version Gemfile Gemfile.lock ./

RUN bundle install
