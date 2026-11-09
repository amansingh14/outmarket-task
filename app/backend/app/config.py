from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration, sourced from environment variables (12-factor)."""

    model_config = SettingsConfigDict(env_prefix="", case_sensitive=False)

    database_url: str = "postgresql+psycopg://ideas:ideas@localhost:5432/ideas"
    app_version: str = "dev"
    log_level: str = "INFO"
    cors_origins: str = "*"
    max_idea_length: int = 500


@lru_cache
def get_settings() -> Settings:
    return Settings()
