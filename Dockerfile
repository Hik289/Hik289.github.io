FROM ruby:3.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000 website && useradd -m -u 1000 -g website website

WORKDIR /usr/src/app

COPY Gemfile ./
RUN gem install bundler:2.3.26 && bundle install

COPY --chown=website:website . .
RUN chown website:website /usr/src/app

USER website
RUN bundle exec jekyll build --strict_front_matter --config _config.yml,_config_docker.yml

EXPOSE 4000

CMD ["bundle", "exec", "jekyll", "serve", "-H", "0.0.0.0", "--config", "_config.yml,_config_docker.yml"]
