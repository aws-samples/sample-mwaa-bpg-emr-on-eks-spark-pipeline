#FROM public.ecr.aws/docker/library/maven:3.8.6-amazoncorretto-17
FROM public.ecr.aws/docker/library/maven@sha256:f503dcd8524c0b6db676d2607c4b6f384f276f98aa914fb6ab761c58e96120c7

ARG VERSION="UNKNOWN"
ARG BUILD_TIME="UNKNOWN"
ARG GIT_COMMIT="UNKNOWN"

# Switch to root user to install packages
USER root

WORKDIR /gateway

# Copy all files
COPY ./src ./src
RUN  sed -i -e "s/INJECT_VERSION/${VERSION}/g"  \
    -e "s/INJECT_GIT_COMMIT/${GIT_COMMIT}/g" \
    -e "s/INJECT_BUILD_TIME/${BUILD_TIME}/g" ./src/main/resources/version.txt
COPY ./build ./build
COPY ./pom.xml ./pom.xml
COPY ./entrypoint.sh /opt/entrypoint.sh

# Package
RUN mvn clean package -Dmaven.test.skip

EXPOSE 8080

RUN chmod 0755 /opt/entrypoint.sh

# Create a non-root user and switch to it
RUN yum install -y shadow-utils && \
    useradd -ms /bin/bash bpguser && \
    yum clean all

USER bpguser

ENTRYPOINT ["/opt/entrypoint.sh"]

CMD ["config.yml"]

# Add a HEALTHCHECK instruction
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["curl", "-u", "admin:admin", "-f", "http://localhost:8080/skatev2/healthcheck/status"] || exit 1