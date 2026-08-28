from __future__ import annotations

from typing import Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field


class WireModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class QuantitySample(WireModel):
    uuid: str = Field(min_length=1, max_length=128)
    type: str = Field(min_length=1, max_length=255)
    value: float
    unit: str | None = None
    start_date: str
    end_date: str
    source_name: str | None = None
    source_bundle_id: str | None = None
    device_name: str | None = None
    metadata: str | None = None


class CategorySample(WireModel):
    uuid: str = Field(min_length=1, max_length=128)
    type: str = Field(min_length=1, max_length=255)
    value: int
    value_label: str | None = None
    start_date: str
    end_date: str
    source_name: str | None = None
    source_bundle_id: str | None = None
    device_name: str | None = None
    metadata: str | None = None


class Workout(WireModel):
    uuid: str = Field(min_length=1, max_length=128)
    activity_type: str = Field(min_length=1, max_length=255)
    duration_seconds: float
    total_energy_burned_kcal: float | None = None
    total_distance_meters: float | None = None
    total_swimming_strokes: float | None = None
    total_flights_climbed: float | None = None
    start_date: str
    end_date: str
    source_name: str | None = None
    source_bundle_id: str | None = None
    device_name: str | None = None
    metadata: str | None = None


class WorkoutRoute(WireModel):
    uuid: str = Field(min_length=1, max_length=128)
    workout_uuid: str = Field(min_length=1, max_length=128)
    start_date: str
    location_count: int = Field(ge=0)
    locations_json: str | None = None


class ActivitySummary(WireModel):
    date: str
    active_energy_burned: float | None = None
    active_energy_burned_goal: float | None = None
    exercise_time_minutes: float | None = None
    exercise_time_goal_minutes: float | None = None
    stand_hours: int | None = None
    stand_hours_goal: int | None = None


class DeviceCapabilities(WireModel):
    device_id: str = Field(min_length=8, max_length=128)
    app_version: str | None = Field(default=None, max_length=64)
    platform_version: str | None = Field(default=None, max_length=160)
    health_data_available: bool
    health_permissions_requested: bool
    supported_quantity_types_json: str = Field(max_length=100_000)
    supported_domains_json: str = Field(max_length=10_000)
    reported_at: str


RecordT = TypeVar("RecordT", bound=WireModel)


class Envelope(WireModel, Generic[RecordT]):
    records: list[RecordT] = Field(max_length=500)


class IngestResponse(WireModel):
    accepted: int
    rejected: int = 0


class ReconcileRequest(WireModel):
    table: str
    type_column: str | None = None
    type_value: str | None = None
    since: str
    until: str
    valid_uuids: list[str] = Field(max_length=5000)
