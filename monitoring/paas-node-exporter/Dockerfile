FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

RUN microdnf install -y python3 python3-pip ethtool \
    && pip3 install --no-cache-dir prometheus_client \
    && microdnf clean all

COPY exporter.py /app/exporter.py
WORKDIR /app

ENV COMMAND_FILE_LOC=/app/commands \
    METRICS_PORT=8000 \
    HOSTNAME_PATH=/host/proc/sys/kernel/hostname

EXPOSE 8000
CMD ["python3", "/app/exporter.py"]
