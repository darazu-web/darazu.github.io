FROM python:3.12-slim
WORKDIR /app
COPY server.py sample-data.json ./
COPY static ./static
VOLUME ["/app/data"]
EXPOSE 8080
CMD ["python", "server.py", "--port", "8080"]
