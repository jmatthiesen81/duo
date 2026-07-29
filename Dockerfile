FROM alpine:3.19

RUN apk add --no-cache bash git

COPY scripts/publish-dist-release.sh /usr/local/bin/publish-dist-release.sh
RUN chmod +x /usr/local/bin/publish-dist-release.sh

ENTRYPOINT ["publish-dist-release.sh"]
