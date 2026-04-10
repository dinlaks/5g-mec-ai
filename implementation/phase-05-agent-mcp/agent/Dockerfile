FROM registry.access.redhat.com/ubi9/python-311:latest

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py state.py ./

EXPOSE 8080

CMD ["python", "agent.py"]
