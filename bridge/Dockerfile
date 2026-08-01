FROM python:3.12-slim

WORKDIR /app

COPY pyproject.toml ./
COPY app ./app
# Без запасного варианта намеренно. Прежняя строка выглядела так:
#   pip install -e . 2>/dev/null || pip install fastapi ... httpx ...
# и глушила ошибку сборки: установка молча уходила на второй, захардкоженный
# список версий, а pyproject.toml не участвовал. Собиралось, но не то.
# Сломанная сборка обязана падать, а не подменяться.
RUN pip install --no-cache-dir .

COPY static ./static

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
