FROM ruby:3.1.3

WORKDIR /workspace

COPY Gemfile Gemfile.lock .ruby-version ./

RUN gem install bundler:2.3.26 && \
    bundle install
