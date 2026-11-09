"""AI copilots for the delivery pipeline.

Design rule used throughout: the model *proposes* typed, schema-validated data;
deterministic code *disposes* (applies guardrails, renders files, executes).
The model never emits free-form shell or IaC text that runs unchecked.
"""
