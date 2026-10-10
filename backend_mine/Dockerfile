FROM python:3.11-slim

WORKDIR /app
COPY pyproject.toml ./
COPY handson_backend ./handson_backend
RUN pip install --no-cache-dir .

EXPOSE 8000
CMD ["uvicorn", "handson_backend.server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--ws-max-size", "524288"]
