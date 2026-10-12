FROM python:3.13-slim

WORKDIR /app

RUN useradd --create-home appuser

COPY temperature.py .

USER appuser

CMD ["python3", "-c", "from temperature import celsius_to_fahrenheit as c; print(c(100))"]