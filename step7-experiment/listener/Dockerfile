FROM python:3.11-slim

WORKDIR /app
COPY listener.py .

RUN apt-get update && apt-get install -y --no-install-recommends \
    stress-ng \
    iproute2 \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["python3", "listener.py"]
CMD ["--port", "5000", "--interval", "1", "--timeout", "30", "--output", "/data/results.csv"]
