FROM python:3.11-slim

WORKDIR /app
COPY talker.py .

# stress-ng for CPU load generation
RUN apt-get update && apt-get install -y --no-install-recommends \
    stress-ng \
    iproute2 \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["python3", "talker.py"]
CMD ["--target", "listener-svc", "--port", "5000", "--interval", "1", "--count", "10000"]
