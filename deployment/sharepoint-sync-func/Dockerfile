FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY *.py ./

# Run as non-root user
RUN useradd --create-home --no-log-init --shell /bin/bash --uid 1001 appuser
USER appuser

# Run the sync job
CMD ["python", "main.py"]
