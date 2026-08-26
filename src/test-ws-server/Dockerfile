FROM public.ecr.aws/docker/library/python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN useradd -r -s /bin/false appuser
USER appuser

EXPOSE 8765 8766

CMD ["python", "app.py"]
