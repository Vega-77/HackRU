FROM python:3.11-slim

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends libegl1 libgles2 libglib2.0-0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
# mediapipe pulls in opencv-contrib-python, the desktop build, which
# overwrites the headless cv2 and needs libGL (absent here), so the server
# crashed on start. Swap every OpenCV build for the headless contrib one,
# which keeps mediapipe working, then check cv2 imports at build time.
RUN pip uninstall -y opencv-python opencv-contrib-python opencv-python-headless \
    && pip install --no-cache-dir opencv-contrib-python-headless \
    && python -c "import cv2; print('OpenCV', cv2.__version__)"
COPY backend/ ./backend/
COPY physics_engine/ ./physics_engine/

WORKDIR /app/backend
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--ws-max-size", "1048576"]
