# JRE_IMAGE: runtime base image (E3 swaps in eclipse-temurin:25-jre to test the
# fix on JDK 25 with identical bytecode; the build stage stays on 21).
ARG JRE_IMAGE=eclipse-temurin:21-jre

FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
COPY src ./src
RUN mvn -q -e -DskipTests package

FROM ${JRE_IMAGE}
COPY --from=build /build/target/vt-repro.jar /app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app.jar"]
