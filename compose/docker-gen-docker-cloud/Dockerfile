FROM jwilder/docker-gen

# From https://github.com/gliderlabs/docker-alpine/blob/master/docs/usage.md#example
#RUN apk add --update \
#    python \
#    py-pip \
#  && pip install virtualenv \
#  && pip install docker-cloud \
#  && rm -rf /var/cache/apk/*

ENV DEBUG=false              \
    DOCKER_GEN_VERSION=0.7.3

RUN apk --update add bash curl ca-certificates procps jq tar && \
    curl -L -O https://github.com/jwilder/docker-gen/releases/download/$DOCKER_GEN_VERSION/docker-gen-linux-amd64-$DOCKER_GEN_VERSION.tar.gz && \
    tar -C /usr/local/bin -xvzf docker-gen-linux-amd64-$DOCKER_GEN_VERSION.tar.gz && \
    rm -f docker-gen-linux-amd64-$DOCKER_GEN_VERSION.tar.gz && \
    apk del tar && \
    rm -rf /var/cache/apk/*


COPY restart_service.sh /restart_service.sh
RUN chmod u+x /restart_service.sh
