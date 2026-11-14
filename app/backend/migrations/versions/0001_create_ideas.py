"""create ideas table

Revision ID: 0001
Revises:
Create Date: 2026-11-09
"""

import sqlalchemy as sa
from alembic import context, op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Databases created before migrations existed already have the table (it used to be created by
    # SQLAlchemy create_all); adopt it instead of failing. Offline mode (`--sql`, for reviewing the
    # SQL) has no live connection to inspect, so it always emits the full DDL.
    if not context.is_offline_mode() and sa.inspect(op.get_bind()).has_table("ideas"):
        return
    op.create_table(
        "ideas",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("content", sa.String(length=1000), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_ideas_created_at", "ideas", ["created_at"])


def downgrade() -> None:
    op.drop_index("ix_ideas_created_at", table_name="ideas")
    op.drop_table("ideas")
