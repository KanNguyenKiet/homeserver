FROM python:3.12-alpine AS builder

WORKDIR /site
COPY requirements.txt mkdocs.yml ./
COPY docs ./docs

RUN pip install --no-cache-dir -r requirements.txt \
    && mkdocs build --strict

FROM nginxinc/nginx-unprivileged:1.27-alpine

COPY --from=builder /site/site /usr/share/nginx/html
COPY nginx/default.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080
