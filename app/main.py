import os
from fastapi import FastAPI, Response, status

app = FastAPI(title="BlueGreenDemoApp")

APP_VERSION = os.getenv("APP_VERSION", "v1.0.0")
APP_COLOR = os.getenv("APP_COLOR", "blue")

# Chaos flag: when set to "true", the container will intentionally fail health checks
FAIL_HEALTH = os.getenv("FAIL_HEALTH", "false").lower() == "true"


@app.get("/")
def read_root(response: Response):
    if FAIL_HEALTH:
        response.status_code = status.HTTP_500_INTERNAL_SERVER_ERROR
        return {
            "status": "error",
            "message": f"Hello from the {APP_COLOR.upper()} deployment slot! (Deployed via CI/CD)"
        }

    return {
        "status": "healthy",
        "version": APP_VERSION,
        "slot": APP_COLOR,
        "message": f"Hello from the {APP_COLOR.upper()} deployment slot!"
    }


@app.get("/health")
def health_check(response: Response):
    if FAIL_HEALTH:
        response.status_code = status.HTTP_500_INTERNAL_SERVER_ERROR
        return {
            "status": "DOWN",
            "slot": APP_COLOR,
            "error": "Simulated startup failure"
        }

    return {
        "status": "UP",
        "slot": APP_COLOR,
        "version": APP_VERSION
    }
