FROM python:3.12-slim
ARG SERVICE
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY common ./common
COPY ${SERVICE} ./svc

ENV PYTHONUNBUFFERED=1 PYTHONPATH=/app
CMD ["python", "-u", "svc/main.py"]
