FROM ruby:3.1.3

WORKDIR /workspace

COPY Gemfile Gemfile.lock ./

RUN gem install bundler -v 2.3.26 --no-document && \
    bundle install
