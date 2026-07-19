# =============================================================================
# QGIS Python Console script (PyQGIS) — EroMapper processing pipeline
# RAW (EPSG:4258) -> PROCESSED (EPSG:4647)
#
# Modules:
# 1) Linear erosion: RAW "Linear_Erosion_Measurement_Points" ->
#    Measurement_Points_Processed + Measurement_Lines_Processed
# 2) Sheet-to-linear: RAW "Sheet_To_Linear_Linear_Measurement_Points" +
#    "Sheet_To_Linear_Area" ->
#    Measurement_Points_SheetToLinear_Processed +
#    Measurement_Lines_SheetToLinear_Processed +
#    Sheet_To_Linear_Processed
# 3) Sheet erosion: RAW "Sheet_Erosion" -> Sheet_Erosion_Processed
# 4) Large deposition: RAW "Large_Deposition_Area" +
#    "Large_Deposition_Measurement_Points" -> Large_Deposition_Processed
# 5) Small deposition: RAW "Small_Deposition" -> Small_Deposition_Processed
# 6) Copy linear: RAW "Copy_linear" (start/end point pairs) ->
#    Copy_Linear_Lines_Processed + Copy_Linear_Points_Processed
# 7) Runoff: RAW "Runoff" -> Runoff_Processed
# 8) Overland water flow: RAW "Overland_water_flow" -> Overland_water_flow_Processed
# 9) Notes: RAW note points + note areas -> Notes_Processed as points;
#    note areas are converted to centroids
# 10) Management: RAW "Management" -> update Parcels attributes; unmatched observations use ABP_ID 9999
#
# Global running number per Date across all modules:
#   Erosion_Parcel_ID = "<ABP_ID>_<dd.MM.yyyy>_<sequence>"
#   where sequence increments globally per date
#
# Idempotency: no new fields are created.
# Existing output signatures are used to skip duplicates.
# =============================================================================

from qgis.core import (
    QgsVectorLayer,
    QgsProject,
    QgsSpatialIndex,
    QgsGeometry,
    QgsPointXY,
    QgsCoordinateTransform,
    QgsFeature,
    QgsDistanceArea,
    QgsField,
    QgsWkbTypes,
)
from PyQt5.QtCore import QVariant
from collections import defaultdict
import re


# ----------------------------
# PATHS / LAYER NAMES
# ----------------------------
RAW_GPKG = r"C:\Users\barthe-n\QField\cloud\test_local\erosion_data.gpkg"
PROC_GPKG = r"C:\Users\barthe-n\QField\cloud\test_local\erosion_data_processed.gpkg"

# RAW
RAW_LINEAR_POINTS = "Linear_Erosion_Measurement_Points"
RAW_SHEET_TO_LINEAR_POINTS = "Sheet_To_Linear_Linear_Measurement_Points"
RAW_SHEET_TO_LINEAR_AREAS = "Sheet_To_Linear_Area"
RAW_SHEET_EROSION_AREAS = "Sheet_Erosion"
RAW_LARGE_DEPOSITION_POINTS = "Large_Deposition_Measurement_Points"
RAW_LARGE_DEPOSITION_AREAS = "Large_Deposition_Area"
RAW_COPY_LINEAR_POINTS = "Copy_linear"
RAW_RUNOFF = "Runoff"
RAW_OVERLAND_WATER_FLOW = "Overland_water_flow"
RAW_NOTE_POINTS = "Note_Point"
RAW_NOTE_AREAS = "Note_Area"
RAW_MANAGEMENT = "Management"
RAW_SMALL_DEPOSITION = "Small_Deposition"

# PROCESSED
PROCESSED_PARCELS = "Parcels"
PROCESSED_EROSION_SYSTEMS = "Erosion_Systems_Processed"
PROCESSED_MEASUREMENT_POINTS = "Measurement_Points_Processed"
PROCESSED_MEASUREMENT_LINES = "Measurement_Lines_Processed"
PROCESSED_SHEET_TO_LINEAR_POINTS = "Measurement_Points_SheetToLinear_Processed"
PROCESSED_SHEET_TO_LINEAR_LINES = "Measurement_Lines_SheetToLinear_Processed"
PROCESSED_SHEET_TO_LINEAR_AREAS = "Sheet_To_Linear_Processed"
PROCESSED_SHEET_EROSION = "Sheet_Erosion_Processed"
PROCESSED_LARGE_DEPOSITION = "Large_Deposition_Processed"
PROCESSED_SMALL_DEPOSITION = "Small_Deposition_Processed"
PROCESSED_COPY_LINEAR_LINES = "Copy_Linear_Lines_Processed"
PROCESSED_COPY_LINEAR_POINTS = "Copy_Linear_Points_Processed"
PROCESSED_RUNOFF = "Runoff_Processed"
PROCESSED_OVERLAND_WATER_FLOW = "Overland_water_flow_Processed"
PROCESSED_NOTES = "Notes_Processed"
PROCESSED_NOTES_AREA = "Notes_Area_Processed"


# ----------------------------
# CONSTANTS
# ----------------------------
DENSITY_T_PER_M3 = 1.45
BUFFER_M = 8.0

# Management observations without an underlying parcel are preserved as
# attribute-only records in Parcels using this default ABP_ID.
MANAGEMENT_FALLBACK_ABP_ID = 9999

# -----------------------------------------------------------------------------
# Erosion_Systems_Processed writing / linking switches
# -----------------------------------------------------------------------------
# WRITE_SYS_RECORDS:
#   True  -> append one record per processed erosion event into
#            Erosion_Systems_Processed
#   False -> do not touch Erosion_Systems_Processed
#
# LINK_EROSION_SYSTEM_ID:
#   True  -> fill Erosion_System_ID in Erosion_Systems_Processed and propagate
#            it into the output erosion layers
#   False -> leave Erosion_System_ID NULL and do not propagate it yet
WRITE_SYS_RECORDS = True
LINK_EROSION_SYSTEM_ID = False

# Erosion form data model:
#   Erosion_Form_1 and Erosion_Form_2 are stored ONLY in
#   Erosion_Systems_Processed.
#
#   Detailed processed layers are linked to Erosion_Systems_Processed through
#   Erosion_Parcel_ID. Erosion_System_ID is additionally populated only when
#   LINK_EROSION_SYSTEM_ID is True.
#
#   Linear erosion:
#     Erosion_Form_1 = "Linear erosion"
#     Erosion_Form_2 = RAW Linear_Erosion_Measurement_Points.Type
#   Sheet-to-linear erosion:
#     Erosion_Form_1 = "Sheet-to-linear erosion"
#     Erosion_Form_2 = RAW Sheet_To_Linear_Area.Type
#   Sheet erosion:
#     Erosion_Form_1 = "Sheet erosion"
#     Erosion_Form_2 = normalized RAW Sheet_Erosion.Type
#   Copy linear:
#     Erosion_Form_1 = "Linear erosion"
#     Erosion_Form_2 = linked RAW linear erosion type

BUF_SEGMENTS = 16
BUF_CAP = QgsGeometry.CapFlat
BUF_JOIN = QgsGeometry.JoinStyleRound
BUF_MITER = 2.0

MAX_SEGMENT_M_WARN = 500.0

# Idempotency signature rounding
CENTROID_ROUND_M = 0.01
AREA_ROUND = 3
LEN_ROUND = 3


# =============================================================================
# LOADERS / EDIT HELPERS
# =============================================================================
def load_layer(gpkg_path, layer_name):
    uri = f"{gpkg_path}|layername={layer_name}"
    layer = QgsVectorLayer(uri, layer_name, "ogr")
    if not layer.isValid():
        raise RuntimeError(f"Layer could not be loaded: {layer_name} from {gpkg_path}")
    return layer


def try_load_layer(gpkg_path, layer_name):
    try:
        return load_layer(gpkg_path, layer_name)
    except Exception:
        return None


def ensure_edit(layer):
    if not layer.isEditable():
        if not layer.startEditing():
            raise RuntimeError(f"Could not start editing layer: {layer.name()}")


def commit(layer):
    if layer.isEditable():
        if not layer.commitChanges():
            raise RuntimeError(f"Commit failed: {layer.name()}")


def field_names(layer):
    return [field.name() for field in layer.fields()]


def resolve_field_name(layer, requested_name):
    """
    Return the real field name using a case-insensitive comparison.

    Examples:
      requested "Crop" can match "Crop", "crop", or "CROP".
    """
    requested_key = str(requested_name).casefold()
    matches = [
        field.name()
        for field in layer.fields()
        if field.name().casefold() == requested_key
    ]

    if not matches:
        return None

    if len(matches) > 1:
        raise RuntimeError(
            f'Layer "{layer.name()}" has multiple fields matching '
            f'"{requested_name}" case-insensitively: {matches}'
        )

    return matches[0]


def resolve_first_field_name(layer, candidate_names):
    """
    Return the first matching field from a list of accepted aliases.

    Matching is case-insensitive.
    """
    for candidate_name in candidate_names:
        actual_name = resolve_field_name(layer, candidate_name)
        if actual_name is not None:
            return actual_name
    return None


# =============================================================================
# SAFE HELPERS
# =============================================================================
def safe_float(value):
    if value is None:
        return None
    try:
        return float(value)
    except Exception:
        try:
            return float(str(value).replace(",", "."))
        except Exception:
            return None


def safe_int(value):
    if value is None:
        return None
    try:
        return int(value)
    except Exception:
        try:
            return int(float(str(value).replace(",", ".")))
        except Exception:
            return None


def max_int_field(layer, field_name):
    """Return max integer value of a field across all features (0 if missing/empty)."""
    if layer is None:
        return 0

    try:
        names = [field.name() for field in layer.fields()]
    except Exception:
        try:
            names = layer.fields().names()
        except Exception:
            names = []

    if field_name not in names:
        return 0

    max_value = 0
    for feature in layer.getFeatures():
        value = safe_int(feature[field_name])
        if value is not None and value > max_value:
            max_value = value
    return max_value


def date_only_str(qdt):
    if qdt is None:
        return None
    try:
        d = qdt.date()
        return f"{d.day():02d}.{d.month():02d}.{d.year():04d}"
    except Exception:
        s = str(qdt)
        if "T" in s and "-" in s:
            yyyy, mm, dd = s.split("T")[0].split("-")
            return f"{dd}.{mm}.{yyyy}"
        return None


def month_from_ddmmyyyy(date_str):
    """Extract month as int from 'dd.MM.yyyy' string."""
    if not date_str:
        return None
    try:
        parts = str(date_str).strip().split(".")
        if len(parts) >= 2:
            return int(parts[1])
    except Exception:
        return None
    return None


def year_from_ddmmyyyy(date_str):
    if not date_str:
        return None
    try:
        parts = str(date_str).strip().split(".")
        if len(parts) == 3:
            return int(parts[2])
    except Exception:
        return None
    return None


def half_year_from_ddmmyyyy(date_str):
    """Project rule: Winter if month in {1, 2, 3}, otherwise Summer."""
    month = month_from_ddmmyyyy(date_str)
    if month in (1, 2, 3):
        return "Winter"
    if month is None:
        return None
    return "Summer"


def qdatetime_from_ddmmyyyy(date_str: str):
    """Return QDateTime at 12:00 local time for a dd.MM.yyyy string."""
    try:
        from PyQt5.QtCore import QDate, QTime, QDateTime
        if not date_str:
            return None
        parts = str(date_str).strip().split(".")
        if len(parts) != 3:
            return None
        day, month, year = int(parts[0]), int(parts[1]), int(parts[2])
        return QDateTime(QDate(year, month, day), QTime(12, 0, 0))
    except Exception:
        return None


def normalize_side_wall(value):
    s = "" if value is None else str(value).strip()
    if not s:
        return "straight"
    if s.lower() == "curved":
        return "curved"
    return "straight"


def wheel_track_count_from_both_tracks_flag(value):
    if value is None:
        return 1
    if isinstance(value, bool):
        return 2 if value else 1

    int_value = safe_int(value)
    if int_value is None:
        try:
            s = str(value).strip().lower()
            if s == "true":
                return 2
            if s == "false":
                return 1
        except Exception:
            pass
        return 1

    return int_value if int_value >= 1 else 1


def round_xy(point_xy, step_m=CENTROID_ROUND_M):
    if point_xy is None:
        return None
    rx = round(point_xy.x() / step_m) * step_m
    ry = round(point_xy.y() / step_m) * step_m
    return (round(rx, 3), round(ry, 3))


def geom_centroid_xy(geometry):
    if geometry is None or geometry.isEmpty():
        return None
    try:
        centroid = geometry.centroid()
        if centroid and not centroid.isEmpty():
            return QgsPointXY(centroid.asPoint())
    except Exception:
        pass
    try:
        point = geometry.boundingBox().center()
        return QgsPointXY(point)
    except Exception:
        return None


# =============================================================================
# CROSS SECTION (cm²) EXACTLY LIKE OLD VBS
# =============================================================================
def calc_cross_section_cm2_vbs(top_width_cm, bottom_width_cm, depth_cm, side_wall):
    top_width = safe_float(top_width_cm)
    bottom_width = safe_float(bottom_width_cm)
    depth = safe_float(depth_cm)

    if top_width is None or depth is None:
        return None
    if bottom_width is None:
        bottom_width = top_width

    side_wall_norm = normalize_side_wall(side_wall)

    if side_wall_norm == "straight":
        return 0.5 * (top_width + bottom_width) * depth

    import math
    pi = math.pi
    diff = top_width - bottom_width
    if abs(diff) < 1e-12:
        return 0.5 * (pi * (depth ** 2) + (depth * bottom_width))
    elif diff > 0:
        return 0.5 * (pi * depth * (top_width - bottom_width) + (bottom_width * depth))
    else:
        return 0.5 * (pi * depth * (bottom_width - top_width) + (top_width * depth))


# =============================================================================
# LEGEND TYPE (VBS mapping; wheel-track count collapsed to 1 vs 2 categories)
# =============================================================================
def legend_type_from_erosion_form2(erosion_form2, depth_cm, wheel_track_count):
    s = "" if erosion_form2 is None else str(erosion_form2).strip()
    depth = safe_float(depth_cm) or 0.0
    tracks = 1 if (wheel_track_count in (None, 0, 1)) else 2
    is_small = depth < 10.0
    sl = s.lower()

    is_rill_or_ditch = (
        ("rill" in sl) or
        ("ditch" in sl) or
        ("channel" in sl)
    )
    is_wheel_track = (
        ("wheel track" in sl) or
        ("wheel tracks" in sl)
    )
    is_furrow = (
        ("furrow" in sl) or
        ("artificial furrow" in sl)
    )

    if is_rill_or_ditch:
        return f"ril{tracks}" if is_small else f"rin{tracks}"
    if is_wheel_track:
        return f"lifa{tracks}" if is_small else f"rinfa{tracks}"
    if is_furrow:
        return f"rilkfu{tracks}" if is_small else f"rinfu{tracks}"
    return "SheetToLinear"


# =============================================================================
# EROSION_PARCEL_ID HELPERS (GLOBAL)
# =============================================================================
def parse_erosion_parcel_id_date(erosion_parcel_id):
    parts = str(erosion_parcel_id).split("_")
    if len(parts) >= 3:
        return parts[1]
    return None


def parse_erosion_parcel_id_suffix(erosion_parcel_id):
    try:
        return int(str(erosion_parcel_id).split("_")[-1])
    except Exception:
        return None


def existing_max_suffix_per_date(layers):
    max_per_date = defaultdict(int)
    for layer in layers:
        if layer is None:
            continue
        if "Erosion_Parcel_ID" not in field_names(layer):
            continue
        for feature in layer.getFeatures():
            erosion_parcel_id = feature["Erosion_Parcel_ID"]
            if erosion_parcel_id is None:
                continue
            date_str = parse_erosion_parcel_id_date(erosion_parcel_id)
            suffix = parse_erosion_parcel_id_suffix(erosion_parcel_id)
            if date_str and suffix is not None and suffix > max_per_date[date_str]:
                max_per_date[date_str] = suffix
    return max_per_date


def existing_erosion_parcel_ids(layers):
    values = set()
    for layer in layers:
        if layer is None:
            continue
        if "Erosion_Parcel_ID" not in field_names(layer):
            continue
        for feature in layer.getFeatures():
            value = feature["Erosion_Parcel_ID"]
            if value is None:
                continue
            value_str = str(value).strip()
            if value_str:
                values.add(value_str)
    return values


def make_global_erosion_parcel_id_allocator(processed_layers_with_erosion_parcel_id):
    """
    Returns:
      alloc(dd, abp_id) -> unique Erosion_Parcel_ID using global per-date suffix
      next_suffix_by_date dict (for debugging)
    """
    max_suffix = existing_max_suffix_per_date(processed_layers_with_erosion_parcel_id)
    next_suffix_by_date = defaultdict(int)
    for date_str, max_value in max_suffix.items():
        next_suffix_by_date[date_str] = max_value
    existing_ids = existing_erosion_parcel_ids(processed_layers_with_erosion_parcel_id)

    def alloc(date_str, abp_id):
        while True:
            next_suffix_by_date[date_str] += 1
            erosion_parcel_id = f"{int(abp_id)}_{date_str}_{next_suffix_by_date[date_str]}"
            if erosion_parcel_id not in existing_ids:
                existing_ids.add(erosion_parcel_id)
                return erosion_parcel_id

    return alloc, next_suffix_by_date


# =============================================================================
# GLOBAL EROSION_PARCEL_ID CONTEXT (one allocator shared across modules)
# =============================================================================
class GlobalIdContext:
    """Global, per-date running-number allocator for Erosion_Parcel_ID."""

    def __init__(self, next_suffix, existing_ids):
        self.next_suffix = next_suffix if next_suffix is not None else defaultdict(int)
        self.existing_ids = existing_ids if existing_ids is not None else set()
        self.collisions = []

    def allocate(self, abp_id, date_str, note=""):
        if date_str is None:
            raise RuntimeError("Cannot allocate Erosion_Parcel_ID: date is None")
        if abp_id is None:
            abp_id = 9999

        while True:
            self.next_suffix[date_str] += 1
            erosion_parcel_id = f"{int(abp_id)}_{date_str}_{int(self.next_suffix[date_str])}"
            if erosion_parcel_id not in self.existing_ids:
                self.existing_ids.add(erosion_parcel_id)
                return erosion_parcel_id
            self.collisions.append(f"[DUP] collision, bumped suffix: {erosion_parcel_id} ({note})")


def build_global_id_context():
    """Build a GlobalIdContext from all processed layers containing Erosion_Parcel_ID."""
    processed_names = [
        PROCESSED_MEASUREMENT_POINTS,
        PROCESSED_MEASUREMENT_LINES,
        PROCESSED_SHEET_TO_LINEAR_POINTS,
        PROCESSED_SHEET_TO_LINEAR_LINES,
        PROCESSED_SHEET_TO_LINEAR_AREAS,
        PROCESSED_SHEET_EROSION,
        PROCESSED_LARGE_DEPOSITION,
        PROCESSED_SMALL_DEPOSITION,
        PROCESSED_COPY_LINEAR_LINES,
        PROCESSED_COPY_LINEAR_POINTS,
        PROCESSED_RUNOFF,
        PROCESSED_OVERLAND_WATER_FLOW,
    ]

    layers = []
    for layer_name in processed_names:
        layer = try_load_layer(PROC_GPKG, layer_name)
        if layer is not None:
            layers.append(layer)

    next_suffix = existing_max_suffix_per_date(layers)
    existing_ids = existing_erosion_parcel_ids(layers)
    return GlobalIdContext(next_suffix, existing_ids)


# =============================================================================
# EROSION SYSTEMS HELPERS
# =============================================================================
def _parse_erosion_event_id(value):
    """Parse Erosion_Event_ID like '<seq>_<dd.MM.yyyy>' -> (dd, seq) or (None, None)."""
    if value is None:
        return None, None
    s = str(value).strip()
    if not s:
        return None, None
    match = re.match(r"^(\d+)_([0-9]{2}\.[0-9]{2}\.[0-9]{4})$", s)
    if not match:
        return None, None
    return match.group(2), int(match.group(1))


def _existing_system_keys(system_layer):
    values = set()
    if system_layer is None:
        return values
    if "Erosion_Parcel_ID" not in field_names(system_layer):
        return values

    for feature in system_layer.getFeatures():
        value = feature["Erosion_Parcel_ID"]
        if value is None:
            continue
        value_str = str(value).strip()
        if value_str:
            values.add(value_str)
    return values


def _existing_max_erosion_event_per_date(system_layer):
    values = defaultdict(int)
    if system_layer is None:
        return values
    if "Erosion_Event_ID" not in field_names(system_layer):
        return values

    for feature in system_layer.getFeatures():
        date_str, seq = _parse_erosion_event_id(feature["Erosion_Event_ID"])
        if date_str and seq is not None and seq > values[date_str]:
            values[date_str] = seq
    return values


def _existing_max_number_of_forms(system_layer):
    values = defaultdict(int)
    if system_layer is None:
        return values

    required = ["ABP_ID", "Date", "Number_of_Forms"]
    if not all(name in field_names(system_layer) for name in required):
        return values

    for feature in system_layer.getFeatures():
        abp_id = safe_int(feature["ABP_ID"])
        date_str = str(feature["Date"]).strip() if feature["Date"] is not None else None
        number_of_forms = safe_int(feature["Number_of_Forms"])
        if abp_id is None or not date_str or number_of_forms is None:
            continue
        key = (int(abp_id), date_str)
        if number_of_forms > values[key]:
            values[key] = number_of_forms

    return values


def _zero_one_fields(feature, field_names_to_reset):
    for name in field_names_to_reset:
        if name in feature.fields().names():
            feature[name] = 0


def _apply_choice_mapping(feature, field_map, choice_str):
    """Set exactly one mapped field to 1; if unknown or empty, set *_NONE if present."""
    choice = "" if choice_str is None else str(choice_str).strip()
    _zero_one_fields(feature, list(field_map.values()))

    target = field_map.get(choice)
    if target is None:
        for _, field_name in field_map.items():
            if "NONE" in field_name.upper():
                target = field_name
                break

    if target and (target in feature.fields().names()):
        feature[target] = 1


class SysContext:
    """Context and allocators for writing Erosion_Systems_Processed."""

    def __init__(self, system_layer, parcels_layer):
        self.sys = system_layer
        self.parcels = parcels_layer

        missing_form_fields = [
            field_name
            for field_name in ("Erosion_Form_1", "Erosion_Form_2")
            if resolve_field_name(system_layer, field_name) is None
        ]
        if missing_form_fields:
            raise RuntimeError(
                "Erosion_Systems_Processed is missing required field(s): "
                + ", ".join(missing_form_fields)
            )

        self.existing_erosion_parcel_ids = _existing_system_keys(system_layer)
        self.next_erosion_event = _existing_max_erosion_event_per_date(system_layer)
        self.next_number_of_forms = _existing_max_number_of_forms(system_layer)

    def allocate_erosion_event_id(self, date_str):
        self.next_erosion_event[date_str] += 1
        return int(self.next_erosion_event[date_str])

    def allocate_number_of_forms(self, abp_id, date_str):
        key = (int(abp_id or 9999), date_str)
        self.next_number_of_forms[key] += 1
        return int(self.next_number_of_forms[key])

    def area_name_for_parcel(self, abp_id):
        if self.parcels is None or abp_id is None:
            return None

        if "Area_Name" in field_names(self.parcels):
            for feature in self.parcels.getFeatures():
                if safe_int(feature["ABP_ID"]) == int(abp_id):
                    return _as_str(feature["Area_Name"]) or None
        return None

    def ensure_sys_record(
        self,
        erosion_parcel_id,
        date_str,
        abp_id,
        erosion_form_1,
        erosion_form_2,
        eroded_mass=None,
        eroded_volume=None,
        erosion_depth_value=None,
        eroded_area_value=None,
        deposition_mass=None,
        deposition_volume=None,
        deposition_depth_value=None,
        deposition_area_value=None,
        raw_sedimentation=None,
        raw_input=None,
        raw_inflow=None,
        raw_outflow=None,
        raw_thalweg=None,
        small_deposition_count=0,
        system_geometry_4647=None,
    ):
        """Create one Erosion_Systems_Processed record, idempotent by Erosion_Parcel_ID."""
        if self.sys is None:
            return None
        if not erosion_parcel_id or str(erosion_parcel_id).strip() == "":
            return None
        if str(erosion_parcel_id) in self.existing_erosion_parcel_ids:
            return None

        event_seq = self.allocate_erosion_event_id(date_str)
        number_of_forms = self.allocate_number_of_forms(abp_id, date_str)

        erosion_event_id = f"{event_seq}_{date_str}"
        erosion_system_id = (
            f"{number_of_forms}_{event_seq}_{date_str}"
            if LINK_EROSION_SYSTEM_ID else None
        )

        year = year_from_ddmmyyyy(date_str)
        half_year = half_year_from_ddmmyyyy(date_str)

        feature = QgsFeature(self.sys.fields())

        if self.sys.wkbType() == QgsWkbTypes.NoGeometry:
            feature.setGeometry(None)
        else:
            point_geom = (
                point_geom_from_feature_geom_4647(system_geometry_4647)
                if system_geometry_4647 is not None else None
            )
            feature.setGeometry(point_geom)

        set_attr_if_exists(self.sys, feature, "Date", date_str)
        set_attr_if_exists(self.sys, feature, "Date_Converted", qdatetime_from_ddmmyyyy(date_str))
        set_attr_if_exists(self.sys, feature, "Erosion_Parcel_ID", str(erosion_parcel_id))
        set_attr_if_exists(self.sys, feature, "Erosion_System_ID", erosion_system_id)
        set_attr_if_exists(self.sys, feature, "Erosion_Event_ID", erosion_event_id)
        set_attr_if_exists(self.sys, feature, "ABP_ID", int(abp_id) if abp_id is not None else 9999)
        set_attr_if_exists(self.sys, feature, "Year", int(year) if year is not None else None)
        set_attr_if_exists(self.sys, feature, "Half_Year", half_year)

        area_name = self.area_name_for_parcel(abp_id)
        set_attr_if_exists(self.sys, feature, "Area_Name", area_name)

        management_id = f"{int(abp_id) if abp_id is not None else 9999}_{date_str}"
        survey_id = None
        if year is not None and half_year:
            survey_id = f"{year}_{int(abp_id) if abp_id is not None else 9999}_{half_year}"

        set_attr_if_exists(self.sys, feature, "Management_ID", management_id)
        set_attr_if_exists(self.sys, feature, "Survey", survey_id)
        set_attr_if_exists(
            self.sys,
            feature,
            "Number_of_Small_Depositions",
            safe_int(small_deposition_count) or 0,
        )

        set_attr_if_exists(self.sys, feature, "Erosion_Form_1", erosion_form_1)
        set_attr_if_exists(self.sys, feature, "Erosion_Form_2", erosion_form_2)
        set_attr_if_exists(self.sys, feature, "Number_of_Forms", float(number_of_forms))

        set_attr_if_exists(self.sys, feature, "Eroded_Mass", safe_float(eroded_mass))
        set_attr_if_exists(self.sys, feature, "Eroded_Volume", safe_float(eroded_volume))
        set_attr_if_exists(self.sys, feature, "Erosion_Depth", safe_float(erosion_depth_value))
        set_attr_if_exists(self.sys, feature, "Eroded_Area", safe_float(eroded_area_value))

        set_attr_if_exists(self.sys, feature, "Deposition_Mass", safe_float(deposition_mass) or 0.0)
        set_attr_if_exists(self.sys, feature, "Deposition_Volume", safe_float(deposition_volume) or 0.0)
        set_attr_if_exists(self.sys, feature, "Deposition_Depth", safe_float(deposition_depth_value) or 0.0)
        set_attr_if_exists(self.sys, feature, "Deposition_Area", safe_float(deposition_area_value) or 0.0)

        sedimentation_map = {
            "No sedimentation": "SEDIMENTATION_NONE",
            "Sedimentation on neighboring parcel": "SEDIMENTATION_PARCEL",
            "Sedimentation on road": "SEDIMENTATION_ROAD",
            "Sedimentation on structure": "SEDIMENTATION_STRUCTURE",
        }
        input_map = {
            "No input": "INPUT_NONE",
            "Input into stream": "INPUT_STREAM",
            "Input into ditch": "INPUT_DITCH",
            "Input into protected biotope": "INPUT_PROTECTED_BIOTOPE",
        }
        inflow_map = {
            "No inflow": "INFLOW_NONE",
            "Bund inflow": "INFLOW_BUND",
            "Inflow from another parcel": "INFLOW_PARCEL",
            "Area inflow": "INFLOW_AREA",
        }
        outflow_map = {
            "No outflow": "OUTFLOW_NONE",
            "Outflow into water furrow": "OUTFLOW_WATER_FURROW",
            "Outflow into drain inlet": "OUTFLOW_DRAIN_INLET",
            "Outflow to road shoulder": "OUTFLOW_SHOULDER",
            "Other outflow": "OUTFLOW_OTHER",
        }

        _apply_choice_mapping(feature, sedimentation_map, raw_sedimentation)
        _apply_choice_mapping(feature, input_map, raw_input)
        _apply_choice_mapping(feature, inflow_map, raw_inflow)
        _apply_choice_mapping(feature, outflow_map, raw_outflow)

        if "Thalweg" in feature.fields().names():
            thalweg_value = _to_bool_int(raw_thalweg)
            feature["Thalweg"] = 1 if thalweg_value == 1 else 0

        self.existing_erosion_parcel_ids.add(str(erosion_parcel_id))
        return feature, erosion_system_id


# =============================================================================
# ABP INDEX + LOOKUP (max Affected_Wheel_Tracks)
# =============================================================================
def build_abp_index(parcels_layer):
    index = QgsSpatialIndex()
    features = {}
    for feature in parcels_layer.getFeatures():
        if not feature.hasGeometry():
            continue
        index.addFeature(feature)
        features[feature.id()] = feature
    return index, features


def abp_lookup_best_for_geom(abp_idx, abp_feats, geom_4647):
    if geom_4647 is None or geom_4647.isEmpty():
        return 9999, None

    candidate_ids = abp_idx.intersects(geom_4647.boundingBox())
    best_abp_id = 9999
    best_affected_tracks = None
    fallback_abp_id = None

    for fid in candidate_ids:
        feature = abp_feats.get(fid)
        if feature is None or not feature.hasGeometry():
            continue
        if not feature.geometry().intersects(geom_4647):
            continue

        abp_id = safe_int(feature["ABP_ID"]) or 9999
        affected_tracks = safe_float(feature["Affected_Wheel_Tracks"])

        if affected_tracks is not None:
            if best_affected_tracks is None or affected_tracks > best_affected_tracks:
                best_affected_tracks = affected_tracks
                best_abp_id = abp_id
        else:
            if fallback_abp_id is None:
                fallback_abp_id = abp_id

    if best_affected_tracks is not None:
        return best_abp_id, best_affected_tracks
    if fallback_abp_id is not None:
        return fallback_abp_id, None
    return 9999, None


def abp_lookup_best_for_poly(abp_idx, abp_feats, poly_geom_4647):
    return abp_lookup_best_for_geom(abp_idx, abp_feats, poly_geom_4647)


def abp_union_geom_for_buffer(abp_idx, abp_feats, buffer_geom):
    candidate_ids = abp_idx.intersects(buffer_geom.boundingBox())
    geometries = []
    for fid in candidate_ids:
        feature = abp_feats.get(fid)
        if feature is None or not feature.hasGeometry():
            continue
        if feature.geometry().intersects(buffer_geom):
            geometries.append(feature.geometry())

    if not geometries:
        return None

    try:
        return QgsGeometry.unaryUnion(geometries)
    except Exception:
        union_geom = geometries[0]
        for geom in geometries[1:]:
            union_geom = union_geom.combine(geom)
        return union_geom


# =============================================================================
# EXISTING SIGNATURE SETS (idempotent skipping)
# =============================================================================
def build_existing_linear_line_signatures(measurement_line_layer):
    signatures = set()
    if measurement_line_layer is None:
        return signatures

    required = ["Date", "Measurement_Line_ID", "ABP_ID", "Erosion_Length"]
    if not all(name in field_names(measurement_line_layer) for name in required):
        return signatures

    for feature in measurement_line_layer.getFeatures():
        date_str = str(feature["Date"]).strip() if feature["Date"] is not None else None
        line_id = safe_int(feature["Measurement_Line_ID"])
        abp_id = safe_int(feature["ABP_ID"])
        erosion_length = safe_float(feature["Erosion_Length"])
        if not date_str or line_id is None or abp_id is None or erosion_length is None:
            continue

        centroid = geom_centroid_xy(feature.geometry()) if feature.hasGeometry() else None
        if centroid is None:
            continue

        signatures.add(
            (
                date_str,
                int(line_id),
                int(abp_id),
                round_xy(centroid),
                round(float(erosion_length), LEN_ROUND),
            )
        )
    return signatures


def build_existing_sheet_to_linear_area_signatures(sheet_to_linear_area_layer):
    signatures = set()
    if sheet_to_linear_area_layer is None:
        return signatures

    required = ["Date", "ABP_ID", "Eroded_Area"]
    if not all(name in field_names(sheet_to_linear_area_layer) for name in required):
        return signatures

    for feature in sheet_to_linear_area_layer.getFeatures():
        date_str = str(feature["Date"]).strip() if feature["Date"] is not None else None
        abp_id = safe_int(feature["ABP_ID"])
        eroded_area = safe_float(feature["Eroded_Area"])
        if not date_str or abp_id is None or eroded_area is None:
            continue

        centroid = geom_centroid_xy(feature.geometry()) if feature.hasGeometry() else None
        if centroid is None:
            continue

        signatures.add(
            (
                date_str,
                int(abp_id),
                round_xy(centroid),
                round(float(eroded_area), AREA_ROUND),
            )
        )
    return signatures


def build_existing_sheet_erosion_signatures(sheet_erosion_layer):
    """
    Duplicate signature for Sheet_Erosion_Processed.

    Erosion_Form_2 is intentionally stored only in
    Erosion_Systems_Processed, so the detailed output signature uses:
      Date + ABP_ID + centroid + eroded area.
    """
    signatures = set()
    if sheet_erosion_layer is None:
        return signatures

    date_field = resolve_field_name(sheet_erosion_layer, "Date")
    abp_field = resolve_field_name(sheet_erosion_layer, "ABP_ID")
    area_field = resolve_field_name(
        sheet_erosion_layer,
        "Eroded_Area",
    )

    if date_field is None or abp_field is None or area_field is None:
        return signatures

    for feature in sheet_erosion_layer.getFeatures():
        date_value = feature[date_field]
        date_str = (
            str(date_value).strip()
            if date_value is not None
            else None
        )
        abp_id = safe_int(feature[abp_field])
        eroded_area = safe_float(feature[area_field])

        if not date_str or abp_id is None or eroded_area is None:
            continue

        centroid = (
            geom_centroid_xy(feature.geometry())
            if feature.hasGeometry()
            else None
        )
        if centroid is None:
            continue

        signatures.add(
            (
                date_str,
                int(abp_id),
                round_xy(centroid),
                round(float(eroded_area), AREA_ROUND),
            )
        )

    return signatures


def build_existing_copy_linear_signatures(copy_linear_line_layer):
    """
    Signature to skip already existing copied linear segment:
      (Date, Measurement_Line_ID, centroid_rounded, length_rounded)
    """
    signatures = set()
    if copy_linear_line_layer is None:
        return signatures

    required = ["Date", "Measurement_Line_ID", "Erosion_Length"]
    if not all(name in field_names(copy_linear_line_layer) for name in required):
        return signatures

    for feature in copy_linear_line_layer.getFeatures():
        date_str = str(feature["Date"]).strip() if feature["Date"] is not None else None
        line_id = safe_int(feature["Measurement_Line_ID"])
        erosion_length = safe_float(feature["Erosion_Length"])
        if not date_str or line_id is None or erosion_length is None:
            continue

        centroid = geom_centroid_xy(feature.geometry()) if feature.hasGeometry() else None
        if centroid is None:
            continue

        signatures.add(
            (
                date_str,
                int(line_id),
                round_xy(centroid),
                round(float(erosion_length), LEN_ROUND),
            )
        )
    return signatures


def print_skips(title, skip_list, max_examples=12):
    if not skip_list:
        return

    print(f"\n=== SKIPPED ({title}) ===")
    print(f"Total skipped: {len(skip_list)}")

    by_date = defaultdict(int)
    for record in skip_list:
        by_date[record.get("date", "?")] += 1

    for date_str in sorted(by_date.keys()):
        print(f"  {date_str}: {by_date[date_str]}")

    print("--- examples ---")
    for record in skip_list[:max_examples]:
        print("  ", record)
    print("=== END SKIPPED ===\n")


def _next_int(layer, field_name, start=0):
    if field_name not in field_names(layer):
        return start + 1

    max_value = None
    for feature in layer.getFeatures():
        int_value = safe_int(feature[field_name])
        if int_value is None:
            continue
        max_value = int_value if max_value is None else max(max_value, int_value)

    if max_value is None:
        max_value = start
    return max_value + 1


def _line_end_signature(date_str, line_id, p0_xy, p1_xy):
    a = round_xy(p0_xy)
    b = round_xy(p1_xy)
    if a is None or b is None:
        return None
    ends = tuple(sorted([a, b]))
    return (date_str, int(line_id), ends[0], ends[1])


def build_existing_copy_linear_line_signatures(copy_linear_line_layer):
    """
    Signature for skipping duplicates without new fields:
      (Date, Measurement_Line_ID, startXY_rounded, endXY_rounded)
    """
    signatures = set()
    names = field_names(copy_linear_line_layer)
    if not all(name in names for name in ["Date", "Measurement_Line_ID"]):
        return signatures

    for feature in copy_linear_line_layer.getFeatures():
        date_str = str(feature["Date"]).strip() if feature["Date"] is not None else None
        line_id = safe_int(feature["Measurement_Line_ID"])
        if not date_str or line_id is None or not feature.hasGeometry():
            continue

        geometry = feature.geometry()
        if geometry is None or geometry.isEmpty():
            continue

        try:
            if geometry.isMultipart():
                lines = geometry.asMultiPolyline()
                if not lines:
                    continue
                line = lines[0]
            else:
                line = geometry.asPolyline()
        except Exception:
            continue

        if not line or len(line) < 2:
            continue

        p0 = QgsPointXY(line[0])
        p1 = QgsPointXY(line[-1])
        signature = _line_end_signature(date_str, line_id, p0, p1)
        if signature:
            signatures.add(signature)

    return signatures


def normalize_runoff_type(value):
    if value is None:
        return None
    value_text = str(value).strip()
    if not value_text:
        return None
    return value_text.lower()


def build_existing_runoff_signatures(output_layer):
    """
    Signature to prevent duplicate Runoff points:
      (Date, Runoff_Type_norm, point_xy_rounded)
    """
    names = field_names(output_layer)
    required = ["Date", "Runoff_Type"]
    signatures = set()

    if not all(name in names for name in required):
        return signatures

    for feature in output_layer.getFeatures():
        date_value = feature["Date"]
        date_str = (
            str(date_value).strip()
            if date_value is not None
            else None
        )
        runoff_type = normalize_runoff_type(
            feature["Runoff_Type"]
        )

        if not date_str or not runoff_type:
            continue

        if not feature.hasGeometry():
            continue

        geometry = feature.geometry()
        if geometry is None or geometry.isEmpty():
            continue

        centroid = geom_centroid_xy(geometry)
        if centroid is None:
            continue

        signatures.add(
            (
                date_str,
                runoff_type,
                round_xy(centroid),
            )
        )

    return signatures


def next_int_from_field(layer, field_name, start=0):
    max_value = None
    if field_name not in field_names(layer):
        return start + 1

    for feature in layer.getFeatures():
        int_value = safe_int(feature[field_name])
        if int_value is None:
            continue
        max_value = int_value if max_value is None else max(max_value, int_value)

    if max_value is None:
        max_value = start
    return max_value + 1


def normalize_overland_water_flow_type(value):
    if value is None:
        return None
    s = str(value).strip()
    if not s:
        return None
    return s.strip()


def build_existing_overland_water_flow_signatures(output_layer):
    """
    Signature to prevent duplicates without adding a custom ID field:
      (Date, Type_norm, point_xy_rounded)

    The GeoPackage FID remains the normal internal row identifier. Raw and
    processed FIDs are not compared because they belong to different tables.
    """
    names = field_names(output_layer)
    required = ["Date", "Type"]
    signatures = set()
    if not all(name in names for name in required):
        return signatures

    for feature in output_layer.getFeatures():
        date_str = str(feature["Date"]).strip() if feature["Date"] is not None else None
        flow_type = normalize_overland_water_flow_type(feature["Type"])
        if not date_str or not flow_type:
            continue
        if not feature.hasGeometry():
            continue

        geometry = feature.geometry()
        if geometry is None or geometry.isEmpty():
            continue

        centroid = geom_centroid_xy(geometry)
        if centroid is None:
            continue

        signatures.add((date_str, flow_type, round_xy(centroid)))

    return signatures


def normalize_note_text(value):
    if value is None:
        return ""
    s = str(value).strip()
    return " ".join(s.split())


def build_existing_note_signatures(output_layer):
    """
    Signature to prevent duplicates without new fields:
      (Date, Note_text, point_xy_rounded)
    """
    names = field_names(output_layer)
    required = ["Date", "Note"]
    signatures = set()
    if not all(name in names for name in required):
        return signatures

    for feature in output_layer.getFeatures():
        date_str = str(feature["Date"]).strip() if feature["Date"] is not None else None
        note_text = normalize_note_text(feature["Note"])
        if not date_str or not note_text:
            continue
        if not feature.hasGeometry():
            continue

        geometry = feature.geometry()
        if geometry is None or geometry.isEmpty():
            continue

        centroid = geom_centroid_xy(geometry)
        if centroid is None:
            continue

        signatures.add((date_str, note_text, round_xy(centroid)))

    return signatures


def point_geom_from_feature_geom_4647(geom_4647):
    """
    Ensure we output a point geometry.
    - if already point => use it
    - else centroid => point
    - fallback bbox center => point
    """
    if geom_4647 is None or geom_4647.isEmpty():
        return None

    try:
        if geom_4647.type() == QgsWkbTypes.PointGeometry:
            try:
                point = geom_4647.asPoint()
                return QgsGeometry.fromPointXY(QgsPointXY(point))
            except Exception:
                multipoint = geom_4647.asMultiPoint()
                if multipoint:
                    return QgsGeometry.fromPointXY(QgsPointXY(multipoint[0]))
    except Exception:
        pass

    centroid = geom_centroid_xy(geom_4647)
    if centroid is None:
        return None
    return QgsGeometry.fromPointXY(QgsPointXY(centroid))


def _as_str(value):
    return "" if value is None else str(value).strip()


def _photo_last10(value):
    s = _as_str(value)
    if not s:
        return None
    return s[-10:] if len(s) > 10 else s


def _photo_last10_noext(value):
    """basename -> drop .jpg/.jpeg -> last 10 chars. Returns None if empty."""
    s = _as_str(value)
    if s is None:
        return None

    import os
    import re as _re

    base = os.path.basename(str(s).strip())
    if not base:
        return None
    base = _re.sub(r"\.(jpe?g)$", "", base, flags=_re.IGNORECASE).strip()
    if not base:
        return None
    return base[-10:] if len(base) > 10 else base


def _to_bool_int(value):
    """
    Convert raw erosion value to 0/1.
    Accepts bool, int, float, and common text booleans.
    """
    if value is None:
        return None
    if isinstance(value, bool):
        return 1 if value else 0

    int_value = safe_int(value)
    if int_value is not None:
        return 1 if int_value != 0 else 0

    s = _as_str(value).lower()
    if s in ("true", "yes", "y"):
        return 1
    if s in ("false", "no", "n"):
        return 0
    return None


def _pick_abp_for_point(abp_idx, abp_feats, point_geom_4647):
    candidate_ids = abp_idx.intersects(point_geom_4647.boundingBox())
    containing_features = []

    for fid in candidate_ids:
        parcel_feature = abp_feats.get(fid)
        if parcel_feature is None or not parcel_feature.hasGeometry():
            continue
        try:
            if parcel_feature.geometry().contains(point_geom_4647):
                containing_features.append(parcel_feature)
        except Exception:
            continue

    if not containing_features:
        return None
    if len(containing_features) == 1:
        return containing_features[0]
    return min(containing_features, key=lambda feature: feature.geometry().area())


def _cast_for_abp_field(abp_layer, field_name, value):
    """
    Cast value to the Parcels field type.
    - String fields: return str/None
    - Numeric fields: float/int
    - DateTime fields: keep QDateTime if already, else None
    """
    if field_name not in field_names(abp_layer):
        return value

    field_def = abp_layer.fields().field(field_name)
    field_type = field_def.type()

    if value is None:
        return None

    if field_type == QVariant.String:
        s = _as_str(value)
        return s if s != "" else None

    if field_type == QVariant.Bool:
        bool_int = _to_bool_int(value)
        return bool(bool_int) if bool_int is not None else None

    if field_type == QVariant.Int or field_type == QVariant.LongLong:
        return safe_int(value)

    if field_type == QVariant.Double:
        return safe_float(value)

    if field_type == QVariant.DateTime:
        try:
            from PyQt5.QtCore import QDateTime
            if isinstance(value, QDateTime):
                return value
        except Exception:
            pass
        return value

    return value


def _prefixed_centroid_note_text(user_text: str) -> str:
    text = (_as_str(user_text) or "").strip()
    return "Note Area (Centroid):" if not text else f"Note Area (Centroid): {text}"


def _photo_clean_noext(value):
    s = _as_str(value)
    if not s:
        return None

    import os
    import re as _re

    base = os.path.basename(str(s).strip())
    base = _re.sub(r"\.(jpe?g)$", "", base, flags=_re.IGNORECASE)
    return base or None


def set_attr_if_exists(layer, feature, field_name, value):
    """
    Set an attribute only when the target field exists.

    Matching is case-insensitive, so Erosion_Form_2 also matches
    erosion_form_2 or EROSION_FORM_2.
    """
    actual_field_name = resolve_field_name(layer, field_name)
    if actual_field_name is None:
        return False

    feature[actual_field_name] = value
    return True


# =============================================================================
# PART 1: LINEAR PROCESSING (with skipping) -- uses global id context
# =============================================================================
def run_linear(idctx, sysctx=None):
    warnings = []
    skipped = []

    raw = load_layer(RAW_GPKG, RAW_LINEAR_POINTS)
    parcels = load_layer(PROC_GPKG, PROCESSED_PARCELS)
    measurement_points = load_layer(PROC_GPKG, PROCESSED_MEASUREMENT_POINTS)
    measurement_lines = load_layer(PROC_GPKG, PROCESSED_MEASUREMENT_LINES)

    transform = QgsCoordinateTransform(raw.crs(), parcels.crs(), QgsProject.instance())

    distance = QgsDistanceArea()
    distance.setSourceCrs(parcels.crs(), QgsProject.instance().transformContext())
    try:
        distance.setEllipsoid(QgsProject.instance().ellipsoid())
    except Exception:
        pass

    parcel_index, parcel_features = build_abp_index(parcels)
    existing_line_signatures = build_existing_linear_line_signatures(measurement_lines)

    # Optional: small deposition counts within the 8 m buffer
    small_deposition_layer = try_load_layer(PROC_GPKG, PROCESSED_SMALL_DEPOSITION)
    small_deposition_index = None
    small_deposition_features = {}
    small_deposition_has_date = False

    if small_deposition_layer is not None:
        try:
            small_deposition_has_date = ("Date" in field_names(small_deposition_layer))
            small_deposition_index = QgsSpatialIndex()
            for feature in small_deposition_layer.getFeatures():
                if not feature.hasGeometry():
                    continue
                small_deposition_index.addFeature(feature)
                small_deposition_features[feature.id()] = feature
        except Exception:
            small_deposition_layer = None
            small_deposition_index = None
            small_deposition_features = {}

    raw_fields = field_names(raw)
    if "Erosion_Line_ID" not in raw_fields:
        raise RuntimeError("RAW linear layer is missing field: Erosion_Line_ID")
    if "Date" not in raw_fields:
        raise RuntimeError("RAW linear layer is missing field: Date")
    if "Last_Point" not in raw_fields:
        warnings.append("[WARN] RAW linear layer is missing field 'Last_Point' -> segment detection may be unreliable.")

    groups = defaultdict(list)
    for feature in raw.getFeatures():
        if not feature.hasGeometry():
            continue

        date_str = date_only_str(feature["Date"])
        if date_str is None:
            warnings.append(f"[WARN] Feature without parseable date (fid={feature.id()}) -> skipped")
            continue

        line_id = safe_int(feature["Erosion_Line_ID"])
        if line_id is None:
            warnings.append(
                f"[WARN] Feature without valid Erosion_Line_ID "
                f"(fid={feature.id()}, date={date_str}) -> skipped"
            )
            continue

        groups[(date_str, line_id)].append(feature)

    new_measurement_points = []
    new_measurement_lines = []
    new_system_records = []

    for (date_str, line_id), features in sorted(groups.items(), key=lambda x: (x[0][0], x[0][1])):
        features_sorted = sorted(features, key=lambda ft: ft["Date"])
        current_segment = []

        def flush_segment(segment_features):
            nonlocal new_measurement_points, new_measurement_lines, existing_line_signatures

            if len(segment_features) < 2:
                warnings.append(
                    f"[WARN] Segment with fewer than 2 points "
                    f"(date={date_str}, line={line_id}) -> ignored."
                )
                return

            points_xy = []
            top_widths = []
            bottom_widths = []
            depths = []
            cross_sections = []
            side_walls = []

            erosion_form_2 = None
            wheel_track_count = 1

            best_abp_id = 9999
            best_affected_tracks = None

            for feature in segment_features:
                geom = QgsGeometry(feature.geometry())
                geom.transform(transform)
                point_xy = QgsPointXY(geom.asPoint())
                points_xy.append(point_xy)

                top_width = feature["Top_Width_cm"] if "Top_Width_cm" in raw_fields else None
                bottom_width = feature["Bottom_Width_cm"] if "Bottom_Width_cm" in raw_fields else None
                depth_cm = feature["Depth_cm"] if "Depth_cm" in raw_fields else None
                side_wall = feature["Side_Wall"] if "Side_Wall" in raw_fields else None
                side_wall = normalize_side_wall(side_wall)

                if "Both_Wheel_Tracks" in raw_fields:
                    wheel_track_count = wheel_track_count_from_both_tracks_flag(feature["Both_Wheel_Tracks"])
                else:
                    wheel_track_count = 1

                if "Type" in raw_fields:
                    erosion_form_2 = feature["Type"]

                cross_section = calc_cross_section_cm2_vbs(
                    top_width,
                    bottom_width,
                    depth_cm,
                    side_wall,
                )

                top_widths.append(safe_float(top_width))
                bottom_widths.append(safe_float(bottom_width))
                depths.append(safe_float(depth_cm))
                side_walls.append(side_wall)
                cross_sections.append(cross_section)

                abp_id, affected_tracks = abp_lookup_best_for_geom(
                    parcel_index,
                    parcel_features,
                    QgsGeometry.fromPointXY(point_xy),
                )
                if abp_id != 9999:
                    if affected_tracks is not None:
                        if best_affected_tracks is None or affected_tracks > best_affected_tracks:
                            best_affected_tracks = affected_tracks
                            best_abp_id = abp_id
                    else:
                        if best_abp_id == 9999:
                            best_abp_id = abp_id

            line_geometry = QgsGeometry.fromPolylineXY(points_xy)
            erosion_length_m = 0.0
            for i in range(len(points_xy) - 1):
                erosion_length_m += distance.measureLine(points_xy[i], points_xy[i + 1])

            centroid_xy = geom_centroid_xy(line_geometry)
            if centroid_xy is not None:
                line_signature = (
                    date_str,
                    int(line_id),
                    int(best_abp_id),
                    round_xy(centroid_xy),
                    round(float(erosion_length_m), LEN_ROUND),
                )
                if line_signature in existing_line_signatures:
                    skipped.append(
                        {
                            "date": date_str,
                            "module": "linear",
                            "Measurement_Line_ID": int(line_id),
                            "ABP_ID": int(best_abp_id),
                            "reason": "signature-exists",
                        }
                    )
                    return
            else:
                warnings.append(
                    f"[WARN] Linear segment centroid empty "
                    f"(date={date_str}, line={line_id}) -> cannot check for duplicates safely"
                )

            for i in range(len(points_xy) - 1):
                segment_length_m = distance.measureLine(points_xy[i], points_xy[i + 1])
                if segment_length_m > MAX_SEGMENT_M_WARN:
                    warnings.append(
                        f"[WARN] Very large point spacing {segment_length_m:.1f} m "
                        f"(date={date_str}, line={line_id}, MP {i+1}->{i+2})."
                    )
                    break

            erosion_parcel_id = idctx.allocate(
                best_abp_id,
                date_str,
                note=f"linear date={date_str} line={line_id}",
            )

            point_distances = []
            base_segment_volumes = []
            segment_point_features = []

            for i in range(len(points_xy)):
                if i == len(points_xy) - 1:
                    point_distance_m = 0.0
                    eroded_volume_m3 = 0.0
                else:
                    point_distance_m = distance.measureLine(points_xy[i], points_xy[i + 1])
                    area1 = cross_sections[i] if cross_sections[i] is not None else 0.0
                    area2 = cross_sections[i + 1] if cross_sections[i + 1] is not None else area1
                    average_area_m2 = ((area1 + area2) / 2.0) / 10000.0
                    eroded_volume_m3 = average_area_m2 * point_distance_m

                point_distances.append(point_distance_m)
                base_segment_volumes.append(eroded_volume_m3)

                point_feature = QgsFeature(measurement_points.fields())
                point_feature.setGeometry(QgsGeometry.fromPointXY(points_xy[i]))
                point_feature["Erosion_Parcel_ID"] = erosion_parcel_id
                point_feature["Date"] = date_str
                point_feature["Measurement_Line_ID"] = int(line_id)
                point_feature["Measurement_Point_ID"] = int(i + 1)
                point_feature["Top_Width"] = top_widths[i]
                point_feature["Bottom_Width"] = bottom_widths[i]
                point_feature["Erosion_Depth"] = depths[i]
                point_feature["Side_Wall_Form"] = side_walls[i]
                point_feature["Cross_Section"] = cross_sections[i]
                point_feature["Point_Distance"] = point_distance_m
                point_feature["Eroded_Volume"] = eroded_volume_m3
                point_feature["Erosion_System_ID"] = None

                new_measurement_points.append(point_feature)
                segment_point_features.append(point_feature)

            top_width_values = [v for v in top_widths if v is not None]
            bottom_width_values = [v for v in bottom_widths if v is not None]
            depth_values = [v for v in depths if v is not None]
            cross_section_values = [v for v in cross_sections if v is not None]

            mean_top_width = (sum(top_width_values) / len(top_width_values)) if top_width_values else None
            mean_bottom_width = (sum(bottom_width_values) / len(bottom_width_values)) if bottom_width_values else None
            mean_depth = (sum(depth_values) / len(depth_values)) if depth_values else None
            mean_cross_section = (sum(cross_section_values) / len(cross_section_values)) if cross_section_values else None

            base_volume_sum = sum(base_segment_volumes)
            total_eroded_volume = base_volume_sum * float(wheel_track_count)
            total_eroded_mass = total_eroded_volume * DENSITY_T_PER_M3

            buffer_geometry = line_geometry.buffer(BUFFER_M, BUF_SEGMENTS, BUF_CAP, BUF_JOIN, BUF_MITER)
            try:
                buffer_geometry = buffer_geometry.makeValid()
            except Exception:
                pass

            parcel_union = abp_union_geom_for_buffer(parcel_index, parcel_features, buffer_geometry)
            intersected_area_m2 = 0.0
            if parcel_union is not None:
                try:
                    parcel_union = parcel_union.makeValid()
                except Exception:
                    pass

                intersection = buffer_geometry.intersection(parcel_union)
                intersected_area_m2 = (
                    intersection.area() if (intersection and not intersection.isEmpty()) else 0.0
                )
            else:
                warnings.append(
                    f"[WARN] No parcel intersection for buffer "
                    f"(date={date_str}, line={line_id}, Erosion_Parcel_ID={erosion_parcel_id})."
                )

            eroded_area_value = round(float(intersected_area_m2), 3)
            erosion_depth_value = None
            if intersected_area_m2 and intersected_area_m2 > 0:
                erosion_depth_value = round(
                    float(total_eroded_mass / (intersected_area_m2 / 10000.0)),
                    3,
                )

            legend_type = legend_type_from_erosion_form2(
                erosion_form_2,
                mean_depth,
                wheel_track_count,
            )

            erosion_system_id = None
            if sysctx is not None:
                small_deposition_count = 0
                if (
                    small_deposition_layer is not None
                    and small_deposition_index is not None
                    and buffer_geometry is not None
                    and (not buffer_geometry.isEmpty())
                ):
                    try:
                        candidate_ids = small_deposition_index.intersects(buffer_geometry.boundingBox())
                        for fid in candidate_ids:
                            small_dep_feature = small_deposition_features.get(fid)
                            if small_dep_feature is None or not small_dep_feature.hasGeometry():
                                continue
                            if small_deposition_has_date:
                                small_dep_date = (
                                    str(small_dep_feature["Date"]).strip()
                                    if small_dep_feature["Date"] is not None else None
                                )
                                if small_dep_date != date_str:
                                    continue
                            if small_dep_feature.geometry().intersects(buffer_geometry):
                                small_deposition_count += 1
                    except Exception:
                        small_deposition_count = 0

                raw_first_feature = segment_features[0]
                raw_sedimentation = raw_first_feature["Sedimentation"] if "Sedimentation" in raw_fields else None
                raw_input = raw_first_feature["Input"] if "Input" in raw_fields else None
                raw_inflow = raw_first_feature["Inflow"] if "Inflow" in raw_fields else None
                raw_outflow = raw_first_feature["Outflow"] if "Outflow" in raw_fields else None
                raw_thalweg = raw_first_feature["Thalweg"] if "Thalweg" in raw_fields else None

                rounded_volume = round(float(total_eroded_volume), 3)
                rounded_mass = round(float(total_eroded_mass), 3)

                system_record = sysctx.ensure_sys_record(
                    erosion_parcel_id=erosion_parcel_id,
                    date_str=date_str,
                    abp_id=best_abp_id,
                    erosion_form_1="Linear erosion",
                    erosion_form_2=erosion_form_2,
                    eroded_mass=rounded_mass,
                    eroded_volume=rounded_volume,
                    erosion_depth_value=erosion_depth_value,
                    eroded_area_value=eroded_area_value,
                    raw_sedimentation=raw_sedimentation,
                    raw_input=raw_input,
                    raw_inflow=raw_inflow,
                    raw_outflow=raw_outflow,
                    raw_thalweg=raw_thalweg,
                    small_deposition_count=small_deposition_count,
                    system_geometry_4647=line_geometry,
                )
                if system_record is not None:
                    system_feature, erosion_system_id = system_record
                    new_system_records.append(system_feature)

            if erosion_system_id:
                for point_feature in segment_point_features:
                    if "Erosion_System_ID" in measurement_points.fields().names():
                        point_feature["Erosion_System_ID"] = erosion_system_id

            line_feature = QgsFeature(measurement_lines.fields())
            line_feature.setGeometry(line_geometry)
            line_feature["Erosion_Parcel_ID"] = erosion_parcel_id
            line_feature["Date"] = date_str
            line_feature["Measurement_Line_ID"] = int(line_id)
            line_feature["Top_Width"] = mean_top_width
            line_feature["Bottom_Width"] = mean_bottom_width
            line_feature["Erosion_Depth"] = mean_depth
            line_feature["Erosion_Length"] = erosion_length_m
            line_feature["Cross_Section"] = mean_cross_section
            line_feature["Number_of_Wheel_Tracks"] = int(wheel_track_count)
            line_feature["Cross_Section_Type"] = ""
            line_feature["Eroded_Volume"] = total_eroded_volume
            line_feature["Eroded_Mass"] = total_eroded_mass
            line_feature["Legend_Type"] = legend_type
            line_feature["ABP_ID"] = int(best_abp_id) if best_abp_id is not None else 9999
            line_feature["Erosion_System_ID"] = erosion_system_id
            line_feature["Eroded_Area"] = eroded_area_value
            line_feature["Erosion_Depth"] = erosion_depth_value

            new_measurement_lines.append(line_feature)

            if centroid_xy is not None:
                existing_line_signatures.add(line_signature)

        if "Last_Point" in raw_fields:
            for feature in features_sorted:
                current_segment.append(feature)
                if bool(feature["Last_Point"]):
                    flush_segment(current_segment)
                    current_segment = []

            if len(current_segment) > 0:
                warnings.append(
                    f"[WARN] Trailing points without Last_Point "
                    f"(date={date_str}, line={line_id}, leftover={len(current_segment)}) -> segment processed."
                )
                if len(current_segment) >= 2:
                    flush_segment(current_segment)
        else:
            flush_segment(features_sorted)

    if new_measurement_points or new_measurement_lines:
        ensure_edit(measurement_points)
        ensure_edit(measurement_lines)

        ok_points, _ = measurement_points.dataProvider().addFeatures(new_measurement_points)
        ok_lines, _ = measurement_lines.dataProvider().addFeatures(new_measurement_lines)

        if not ok_points:
            raise RuntimeError("Append failed: Measurement_Points_Processed")
        if not ok_lines:
            raise RuntimeError("Append failed: Measurement_Lines_Processed")

        commit(measurement_points)
        commit(measurement_lines)

    if new_system_records and sysctx is not None and sysctx.sys is not None:
        ensure_edit(sysctx.sys)
        ok_systems, _ = sysctx.sys.dataProvider().addFeatures(new_system_records)
        if not ok_systems:
            raise RuntimeError("Append failed: Erosion_Systems_Processed")
        commit(sysctx.sys)

    print("LINEAR DONE ✅")
    print(f"Added Measurement_Points_Processed: {len(new_measurement_points)}")
    print(f"Added Measurement_Lines_Processed: {len(new_measurement_lines)}")
    print_skips("LINEAR", skipped)

    if warnings:
        print("\n=== WARNINGS (LINEAR) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")


# =============================================================================
# PART 2: SHEET-TO-LINEAR PROCESSING (with skipping) -- uses global id context
# =============================================================================
def run_sheet_to_linear(idctx, sysctx=None):
    warnings = []
    skipped = []
    new_system_records = []

    raw_points = load_layer(RAW_GPKG, RAW_SHEET_TO_LINEAR_POINTS)
    raw_areas = load_layer(RAW_GPKG, RAW_SHEET_TO_LINEAR_AREAS)

    parcels = load_layer(PROC_GPKG, PROCESSED_PARCELS)

    sheet_to_linear_points = load_layer(PROC_GPKG, PROCESSED_SHEET_TO_LINEAR_POINTS)
    sheet_to_linear_lines = load_layer(PROC_GPKG, PROCESSED_SHEET_TO_LINEAR_LINES)
    sheet_to_linear_areas = load_layer(PROC_GPKG, PROCESSED_SHEET_TO_LINEAR_AREAS)

    points_transform = QgsCoordinateTransform(raw_points.crs(), parcels.crs(), QgsProject.instance())
    areas_transform = QgsCoordinateTransform(raw_areas.crs(), parcels.crs(), QgsProject.instance())

    distance = QgsDistanceArea()
    distance.setSourceCrs(parcels.crs(), QgsProject.instance().transformContext())

    parcel_index, parcel_features = build_abp_index(parcels)
    existing_area_signatures = build_existing_sheet_to_linear_area_signatures(sheet_to_linear_areas)

    raw_area_fields = field_names(raw_areas)
    raw_point_fields = field_names(raw_points)
    processed_area_fields = field_names(sheet_to_linear_areas)

    # -------------------------------------------------------------------------
    # Build a memory polygon layer in EPSG:4647 + per-polygon attribute caches
    # -------------------------------------------------------------------------
    memory_areas = QgsVectorLayer("Polygon?crs=EPSG:4647", "tmp_sheet_to_linear_area_4647", "memory")
    provider = memory_areas.dataProvider()
    provider.addAttributes([
        QgsField("src_fid", QVariant.Int),
        QgsField("Date", QVariant.String),
        QgsField("Affected_Wheel_Track_Count", QVariant.Int),
        QgsField("Has_Both_Wheel_Tracks", QVariant.Int),
    ])
    memory_areas.updateFields()

    area_geometry_by_mid = {}
    area_srcfid_by_mid = {}
    area_date_by_mid = {}
    area_affected_track_count_by_mid = {}
    area_has_both_tracks_by_mid = {}

    area_sedimentation_by_mid = {}
    area_input_by_mid = {}
    area_inflow_by_mid = {}
    area_outflow_by_mid = {}
    area_thalweg_by_mid = {}
    area_type_by_mid = {}

    temp_features = []
    for raw_area_feature in raw_areas.getFeatures():
        if not raw_area_feature.hasGeometry():
            continue

        geom = QgsGeometry(raw_area_feature.geometry())
        geom.transform(areas_transform)
        try:
            geom = geom.makeValid()
        except Exception:
            pass

        area_date = date_only_str(raw_area_feature["Date"]) if "Date" in raw_area_fields else None

        temp_feature = QgsFeature(memory_areas.fields())
        temp_feature.setGeometry(geom)
        temp_feature["src_fid"] = raw_area_feature.id()
        temp_feature["Date"] = area_date

        affected_track_count = (
            safe_int(raw_area_feature["Affected_Wheel_Tracks"])
            if "Affected_Wheel_Tracks" in raw_area_fields else None
        )
        has_both_tracks = (
            _to_bool_int(raw_area_feature["Both_Wheel_Tracks"])
            if "Both_Wheel_Tracks" in raw_area_fields else None
        )

        temp_feature["Affected_Wheel_Track_Count"] = (
            int(affected_track_count) if affected_track_count is not None else None
        )
        temp_feature["Has_Both_Wheel_Tracks"] = (
            int(has_both_tracks) if has_both_tracks is not None else None
        )

        area_sedimentation_by_mid[raw_area_feature.id()] = (
            raw_area_feature["Sedimentation"] if "Sedimentation" in raw_area_fields else None
        )
        area_input_by_mid[raw_area_feature.id()] = (
            raw_area_feature["Input"] if "Input" in raw_area_fields else None
        )
        area_inflow_by_mid[raw_area_feature.id()] = (
            raw_area_feature["Inflow"] if "Inflow" in raw_area_fields else None
        )
        area_outflow_by_mid[raw_area_feature.id()] = (
            raw_area_feature["Outflow"] if "Outflow" in raw_area_fields else None
        )
        area_thalweg_by_mid[raw_area_feature.id()] = (
            raw_area_feature["Thalweg"] if "Thalweg" in raw_area_fields else None
        )
        area_type_by_mid[raw_area_feature.id()] = (
            raw_area_feature["Type"] if "Type" in raw_area_fields else None
        )

        temp_features.append(temp_feature)

    provider.addFeatures(temp_features)
    memory_areas.updateExtents()

    memory_area_index = QgsSpatialIndex(memory_areas.getFeatures())
    memory_areas_by_id = {feature.id(): feature for feature in memory_areas.getFeatures()}

    for memory_id, memory_feature in memory_areas_by_id.items():
        area_geometry_by_mid[memory_id] = memory_feature.geometry()
        area_srcfid_by_mid[memory_id] = int(memory_feature["src_fid"])
        area_date_by_mid[memory_id] = memory_feature["Date"]
        area_affected_track_count_by_mid[memory_id] = safe_int(memory_feature["Affected_Wheel_Track_Count"])
        area_has_both_tracks_by_mid[memory_id] = safe_int(memory_feature["Has_Both_Wheel_Tracks"])

        source_fid = area_srcfid_by_mid[memory_id]
        area_sedimentation_by_mid[memory_id] = area_sedimentation_by_mid.get(source_fid)
        area_input_by_mid[memory_id] = area_input_by_mid.get(source_fid)
        area_inflow_by_mid[memory_id] = area_inflow_by_mid.get(source_fid)
        area_outflow_by_mid[memory_id] = area_outflow_by_mid.get(source_fid)
        area_thalweg_by_mid[memory_id] = area_thalweg_by_mid.get(source_fid)
        area_type_by_mid[memory_id] = area_type_by_mid.get(source_fid)

    # -------------------------------------------------------------------------
    # RAW points validation + assign points -> polygon
    # -------------------------------------------------------------------------
    for required_field in ["SheetToLinear_Line_ID", "Date"]:
        if required_field not in raw_point_fields:
            raise RuntimeError(f"RAW sheet-to-linear points: Missing field: {required_field}")

    has_last_point_flag = ("Last_Point" in raw_point_fields)

    point_to_area_mid = {}
    for raw_point_feature in raw_points.getFeatures():
        if not raw_point_feature.hasGeometry():
            continue

        geom = QgsGeometry(raw_point_feature.geometry())
        geom.transform(points_transform)
        point_geom = QgsGeometry.fromPointXY(QgsPointXY(geom.asPoint()))

        candidate_ids = memory_area_index.intersects(point_geom.boundingBox())
        containing_areas = [
            memory_id for memory_id in candidate_ids
            if area_geometry_by_mid[memory_id].contains(point_geom)
        ]

        if len(containing_areas) == 1:
            point_to_area_mid[raw_point_feature.id()] = containing_areas[0]
        elif len(containing_areas) > 1:
            best_area = min(containing_areas, key=lambda memory_id: area_geometry_by_mid[memory_id].area())
            point_to_area_mid[raw_point_feature.id()] = best_area
            warnings.append(
                f"[WARN] Sheet-to-linear point {raw_point_feature.id()} intersects multiple polygons -> smallest chosen"
            )
        else:
            warnings.append(
                f"[WARN] Sheet-to-linear point {raw_point_feature.id()} intersects no polygon -> skipped"
            )

    groups = defaultdict(list)
    for raw_point_feature in raw_points.getFeatures():
        memory_id = point_to_area_mid.get(raw_point_feature.id())
        if memory_id is None:
            continue

        date_str = date_only_str(raw_point_feature["Date"])
        line_id = safe_int(raw_point_feature["SheetToLinear_Line_ID"])
        if date_str is None or line_id is None:
            warnings.append(
                f"[WARN] Sheet-to-linear point has invalid date or line id -> skipped "
                f"(fid={raw_point_feature.id()})"
            )
            continue

        groups[(memory_id, date_str, line_id)].append(raw_point_feature)

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------
    def abp_id_for_area_geom(area_geom_4647):
        best_abp_id = 9999
        best_affected_tracks = None
        fallback_abp_id = None

        candidate_ids = parcel_index.intersects(area_geom_4647.boundingBox())
        for fid in candidate_ids:
            parcel_feature = parcel_features.get(fid)
            if parcel_feature is None or not parcel_feature.hasGeometry():
                continue
            if not parcel_feature.geometry().intersects(area_geom_4647):
                continue

            abp_id = safe_int(parcel_feature["ABP_ID"]) or 9999
            affected_tracks = safe_float(parcel_feature["Affected_Wheel_Tracks"])
            if affected_tracks is not None:
                if best_affected_tracks is None or affected_tracks > best_affected_tracks:
                    best_affected_tracks = affected_tracks
                    best_abp_id = abp_id
            else:
                if fallback_abp_id is None:
                    fallback_abp_id = abp_id

        if best_affected_tracks is not None:
            return best_abp_id
        if fallback_abp_id is not None:
            return fallback_abp_id
        return 9999

    def area_event_exists(memory_id, date_str, abp_id):
        area_geom = area_geometry_by_mid[memory_id]
        area_m2 = area_geom.area()
        centroid_xy = geom_centroid_xy(area_geom)
        if centroid_xy is None:
            return False, None

        signature = (
            date_str,
            int(abp_id),
            round_xy(centroid_xy),
            round(float(area_m2), AREA_ROUND),
        )
        return (signature in existing_area_signatures), signature

    def wheel_track_count_for_area(memory_id):
        affected_track_count = int(area_affected_track_count_by_mid.get(memory_id) or 1)
        has_both_tracks = 1 if int(area_has_both_tracks_by_mid.get(memory_id) or 0) == 1 else 0
        return affected_track_count * 2 if has_both_tracks == 1 else affected_track_count

    def area_type_to_erosion_form_2(memory_id):
        value = _as_str(area_type_by_mid.get(memory_id))
        return None if value == "" else value

    # -------------------------------------------------------------------------
    # Event allocator
    # -------------------------------------------------------------------------
    event_info = {}

    def ensure_event(memory_id, date_str):
        key = (memory_id, date_str)
        if key in event_info:
            return event_info[key]

        area_geom = area_geometry_by_mid[memory_id]
        abp_id = abp_id_for_area_geom(area_geom)

        exists, signature = area_event_exists(memory_id, date_str, abp_id)
        if exists:
            event_info[key] = {
                "erosion_parcel_id": None,
                "abp_id": abp_id,
                "skipped": True,
                "signature": signature,
                "erosion_system_id": None,
                "erosion_form_2": area_type_to_erosion_form_2(memory_id),
            }
            skipped.append(
                {
                    "date": date_str,
                    "module": "sheet_to_linear",
                    "raw_area_fid": area_srcfid_by_mid[memory_id],
                    "ABP_ID": int(abp_id),
                    "reason": "polygon-signature-exists",
                }
            )
            return event_info[key]

        erosion_parcel_id = idctx.allocate(
            abp_id,
            date_str,
            note=f"sheet_to_linear date={date_str} raw_area={area_srcfid_by_mid[memory_id]}",
        )
        if signature is not None:
            existing_area_signatures.add(signature)

        event_info[key] = {
            "erosion_parcel_id": erosion_parcel_id,
            "abp_id": abp_id,
            "skipped": False,
            "signature": signature,
            "erosion_system_id": None,
            "erosion_form_2": area_type_to_erosion_form_2(memory_id),
        }
        return event_info[key]

    # -------------------------------------------------------------------------
    # Process line segments + accumulate area totals
    # -------------------------------------------------------------------------
    new_sheet_to_linear_points = []
    new_sheet_to_linear_lines = []
    area_accumulators = defaultdict(lambda: {"volume_m3": 0.0, "mass_t": 0.0, "wheel_track_sum": 0})

    for (memory_id, date_str, line_id), features in groups.items():
        features_sorted = sorted(features, key=lambda f: f["Date"])
        current_segment = []

        def flush_segment(segment_features):
            if len(segment_features) < 2:
                warnings.append(
                    f"[WARN] Sheet-to-linear segment with fewer than 2 points ignored "
                    f"(mid={memory_id}, date={date_str}, line={line_id})"
                )
                return

            event = ensure_event(memory_id, date_str)
            if event.get("skipped"):
                return

            erosion_parcel_id = event["erosion_parcel_id"]
            wheel_track_count = int(wheel_track_count_for_area(memory_id))

            points_xy = []
            top_widths = []
            bottom_widths = []
            depths = []
            cross_sections = []
            side_walls = []

            for feature in segment_features:
                geom = QgsGeometry(feature.geometry())
                geom.transform(points_transform)
                point_xy = QgsPointXY(geom.asPoint())
                points_xy.append(point_xy)

                top_width = feature["Top_Width_cm"] if "Top_Width_cm" in raw_point_fields else None
                bottom_width = feature["Bottom_Width_cm"] if "Bottom_Width_cm" in raw_point_fields else None
                depth_cm = feature["Depth_cm"] if "Depth_cm" in raw_point_fields else None
                side_wall = feature["Side_Wall"] if "Side_Wall" in raw_point_fields else None
                side_wall = normalize_side_wall(side_wall)

                cross_section = calc_cross_section_cm2_vbs(
                    top_width,
                    bottom_width,
                    depth_cm,
                    side_wall,
                )

                top_widths.append(safe_float(top_width))
                bottom_widths.append(safe_float(bottom_width))
                depths.append(safe_float(depth_cm))
                side_walls.append(side_wall)
                cross_sections.append(cross_section)

            segment_volumes = []
            point_distances = []
            for i in range(len(points_xy)):
                if i == len(points_xy) - 1:
                    point_distance_m = 0.0
                    eroded_volume_m3 = 0.0
                else:
                    point_distance_m = distance.measureLine(points_xy[i], points_xy[i + 1])
                    area1 = cross_sections[i] or 0.0
                    area2 = cross_sections[i + 1] or area1
                    eroded_volume_m3 = ((area1 + area2) / 2.0) / 10000.0 * point_distance_m

                point_distances.append(point_distance_m)
                segment_volumes.append(eroded_volume_m3)

                point_feature = QgsFeature(sheet_to_linear_points.fields())
                point_feature.setGeometry(QgsGeometry.fromPointXY(points_xy[i]))
                point_feature["Erosion_Parcel_ID"] = erosion_parcel_id
                point_feature["Date"] = date_str
                point_feature["SheetToLinear_Line_ID"] = int(line_id)
                point_feature["SheetToLinear_Point_ID"] = int(i + 1)
                point_feature["Top_Width"] = top_widths[i]
                point_feature["Bottom_Width"] = bottom_widths[i]
                point_feature["Erosion_Depth"] = depths[i]
                point_feature["Side_Wall_Form"] = side_walls[i]
                point_feature["Cross_Section"] = cross_sections[i]
                point_feature["Point_Distance"] = point_distance_m
                point_feature["Eroded_Volume"] = eroded_volume_m3
                point_feature["Erosion_System_ID"] = None

                new_sheet_to_linear_points.append(point_feature)

            base_volume = sum(segment_volumes)
            base_mass = base_volume * DENSITY_T_PER_M3
            line_geometry = QgsGeometry.fromPolylineXY(points_xy)

            top_width_values = [v for v in top_widths if v is not None]
            bottom_width_values = [v for v in bottom_widths if v is not None]
            depth_values = [v for v in depths if v is not None]
            cross_section_values = [v for v in cross_sections if v is not None]

            mean_top_width = (sum(top_width_values) / len(top_width_values)) if top_width_values else None
            mean_bottom_width = (sum(bottom_width_values) / len(bottom_width_values)) if bottom_width_values else None
            mean_depth = (sum(depth_values) / len(depth_values)) if depth_values else None
            mean_cross_section = (sum(cross_section_values) / len(cross_section_values)) if cross_section_values else None

            line_feature = QgsFeature(sheet_to_linear_lines.fields())
            line_feature.setGeometry(line_geometry)
            line_feature["Erosion_Parcel_ID"] = erosion_parcel_id
            line_feature["Date"] = date_str
            line_feature["SheetToLinear_Line_ID"] = int(line_id)
            line_feature["Top_Width"] = mean_top_width
            line_feature["Bottom_Width"] = mean_bottom_width
            line_feature["Erosion_Depth"] = mean_depth
            line_feature["Erosion_Length"] = float(sum(point_distances))
            line_feature["Cross_Section"] = mean_cross_section
            line_feature["Cross_Section_Type"] = ""
            line_feature["Eroded_Volume"] = round(float(base_volume), 3)
            line_feature["Eroded_Mass"] = round(float(base_mass), 3)
            line_feature["Legend_Type"] = "SheetToLinear"
            line_feature["Erosion_System_ID"] = None
            line_feature["Number_of_Wheel_Tracks"] = int(wheel_track_count)
            line_feature["Aggregation_Type"] = "BASE"

            new_sheet_to_linear_lines.append(line_feature)

            key = (memory_id, date_str)
            area_accumulators[key]["volume_m3"] += float(base_volume) * float(wheel_track_count)
            area_accumulators[key]["mass_t"] += float(base_mass) * float(wheel_track_count)
            area_accumulators[key]["wheel_track_sum"] += int(wheel_track_count)

        if has_last_point_flag:
            for feature in features_sorted:
                current_segment.append(feature)
                if bool(feature["Last_Point"]):
                    flush_segment(current_segment)
                    current_segment = []

            if len(current_segment) >= 2:
                warnings.append(
                    f"[WARN] Sheet-to-linear trailing segment without Last_Point processed "
                    f"(mid={memory_id}, date={date_str}, line={line_id})"
                )
                flush_segment(current_segment)
        else:
            flush_segment(features_sorted)

    # -------------------------------------------------------------------------
    # Build area output + create system records with totals
    # -------------------------------------------------------------------------
    new_sheet_to_linear_areas = []
    erosion_parcel_to_system_id = {}

    for (memory_id, date_str), accumulator in area_accumulators.items():
        event = event_info.get((memory_id, date_str))
        if not event or event.get("skipped"):
            continue

        erosion_parcel_id = event["erosion_parcel_id"]
        abp_id = event["abp_id"]

        area_geom = area_geometry_by_mid[memory_id]
        area_m2 = float(area_geom.area())

        rounded_volume = round(float(accumulator["volume_m3"]), 3)
        rounded_mass = round(float(accumulator["mass_t"]), 3)
        rounded_area = round(area_m2, 3)

        erosion_depth_value = None
        if area_m2 > 0:
            erosion_depth_value = float(accumulator["mass_t"]) / (area_m2 / 10000.0)
        rounded_depth = round(float(erosion_depth_value), 3) if erosion_depth_value is not None else None

        erosion_form_2 = event.get("erosion_form_2")

        erosion_system_id = None
        if sysctx is not None:
            raw_sedimentation = area_sedimentation_by_mid.get(memory_id)
            raw_input = area_input_by_mid.get(memory_id)
            raw_inflow = area_inflow_by_mid.get(memory_id)
            raw_outflow = area_outflow_by_mid.get(memory_id)
            raw_thalweg = area_thalweg_by_mid.get(memory_id)

            system_record = sysctx.ensure_sys_record(
                erosion_parcel_id=erosion_parcel_id,
                date_str=date_str,
                abp_id=abp_id,
                erosion_form_1="Sheet-to-linear erosion",
                erosion_form_2=erosion_form_2,
                eroded_mass=rounded_mass,
                eroded_volume=rounded_volume,
                erosion_depth_value=rounded_depth,
                eroded_area_value=rounded_area,
                raw_sedimentation=raw_sedimentation,
                raw_input=raw_input,
                raw_inflow=raw_inflow,
                raw_outflow=raw_outflow,
                raw_thalweg=raw_thalweg,
                system_geometry_4647=area_geom,
            )
            if system_record is not None:
                system_feature, erosion_system_id = system_record
                new_system_records.append(system_feature)

        event["erosion_system_id"] = erosion_system_id
        erosion_parcel_to_system_id[str(erosion_parcel_id)] = erosion_system_id

        area_feature = QgsFeature(sheet_to_linear_areas.fields())
        area_feature.setGeometry(area_geom)
        area_feature["Erosion_Parcel_ID"] = erosion_parcel_id
        area_feature["Date"] = date_str
        area_feature["ABP_ID"] = int(abp_id)
        area_feature["Eroded_Volume"] = rounded_volume
        area_feature["Eroded_Mass"] = rounded_mass
        area_feature["Eroded_Area"] = rounded_area
        area_feature["Erosion_Depth"] = rounded_depth
        area_feature["Number_of_Wheel_Tracks"] = int(accumulator["wheel_track_sum"])

        affected_track_count_value = int(area_affected_track_count_by_mid.get(memory_id) or 1)
        both_tracks_value = 1 if int(area_has_both_tracks_by_mid.get(memory_id) or 0) == 1 else 0

        if "Affected_Wheel_Tracks" in processed_area_fields:
            area_feature["Affected_Wheel_Tracks"] = affected_track_count_value
        if "Both_Wheel_Tracks" in processed_area_fields:
            area_feature["Both_Wheel_Tracks"] = both_tracks_value

        area_feature["Erosion_System_ID"] = erosion_system_id
        new_sheet_to_linear_areas.append(area_feature)

    # -------------------------------------------------------------------------
    # Propagate Erosion_System_ID into point/line features
    # -------------------------------------------------------------------------
    if erosion_parcel_to_system_id:
        if "Erosion_System_ID" in sheet_to_linear_points.fields().names():
            for feature in new_sheet_to_linear_points:
                erosion_parcel_id = _as_str(feature["Erosion_Parcel_ID"])
                feature["Erosion_System_ID"] = erosion_parcel_to_system_id.get(erosion_parcel_id)

        if "Erosion_System_ID" in sheet_to_linear_lines.fields().names():
            for feature in new_sheet_to_linear_lines:
                erosion_parcel_id = _as_str(feature["Erosion_Parcel_ID"])
                feature["Erosion_System_ID"] = erosion_parcel_to_system_id.get(erosion_parcel_id)

    # -------------------------------------------------------------------------
    # Write outputs
    # -------------------------------------------------------------------------
    if new_sheet_to_linear_points or new_sheet_to_linear_lines or new_sheet_to_linear_areas:
        ensure_edit(sheet_to_linear_points)
        ensure_edit(sheet_to_linear_lines)
        ensure_edit(sheet_to_linear_areas)

        ok_points, _ = sheet_to_linear_points.dataProvider().addFeatures(new_sheet_to_linear_points)
        ok_lines, _ = sheet_to_linear_lines.dataProvider().addFeatures(new_sheet_to_linear_lines)
        ok_areas, _ = sheet_to_linear_areas.dataProvider().addFeatures(new_sheet_to_linear_areas)

        if not ok_points:
            raise RuntimeError("Append failed: Measurement_Points_SheetToLinear_Processed")
        if not ok_lines:
            raise RuntimeError("Append failed: Measurement_Lines_SheetToLinear_Processed")
        if not ok_areas:
            raise RuntimeError("Append failed: Sheet_To_Linear_Processed")

        commit(sheet_to_linear_points)
        commit(sheet_to_linear_lines)
        commit(sheet_to_linear_areas)

    if new_system_records and sysctx is not None and sysctx.sys is not None:
        ensure_edit(sysctx.sys)
        ok_systems, _ = sysctx.sys.dataProvider().addFeatures(new_system_records)
        if ok_systems:
            sysctx.sys.commitChanges()
        else:
            sysctx.sys.rollBack()
            warnings.append("[WARN] Could not add Erosion_Systems_Processed (sheet-to-linear) records")

    print("SHEET-TO-LINEAR DONE ✅")
    print(f"Added Measurement_Points_SheetToLinear_Processed: {len(new_sheet_to_linear_points)}")
    print(f"Added Measurement_Lines_SheetToLinear_Processed: {len(new_sheet_to_linear_lines)}")
    print(f"Added Sheet_To_Linear_Processed: {len(new_sheet_to_linear_areas)}")
    print_skips("SHEET_TO_LINEAR", skipped)

    if warnings:
        print("\n=== WARNINGS (SHEET_TO_LINEAR) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")

# =============================================================================
# PART 3: SHEET EROSION (legacy rate logic, t/ha)
#
# Wheel-track count rule:
# - "Sheet erosion in wheel tracks": positive Affected_Wheel_Tracks required
# - all other sheet-erosion types: wheel-track count is not used and is NULL
# =============================================================================
def normalize_sheet_erosion_form(raw_type):
    """
    Normalize RAW Sheet_Erosion.Type to the exact English values stored in
    Erosion_Systems_Processed.Erosion_Form_2.
    """
    if raw_type is None:
        return None

    value = str(raw_type).strip()
    if not value:
        return None

    value_lower = value.casefold()

    # Current English QML values
    english_values = {
        "sheet erosion": "Sheet erosion",
        "sheet erosion in wheel tracks":
            "Sheet erosion in wheel tracks",
        "sheet erosion in small parallel rills":
            "Sheet erosion in small parallel rills",
    }

    if value_lower in english_values:
        return english_values[value_lower]

    # Backwards compatibility for older German/raw abbreviations.
    if (
        "absp" in value_lower
        and "management" not in value_lower
        and "spur" not in value_lower
        and "kleinstr" not in value_lower
    ):
        return "Sheet erosion"

    if "kleinstr" in value_lower:
        return "Sheet erosion in small parallel rills"

    if (
        "management" in value_lower
        or "spur" in value_lower
    ):
        return "Sheet erosion in wheel tracks"

    return None


def calculate_sheet_erosion_metrics(area_m2, erosion_form_2, affected_wheel_tracks):
    area_ha = float(area_m2) / 10000.0

    if erosion_form_2 == "Sheet erosion":
        erosion_rate = 0.75
        eroded_mass = round(erosion_rate * area_ha, 3)
        eroded_volume = round(eroded_mass / DENSITY_T_PER_M3, 3)
        return erosion_rate, eroded_mass, eroded_volume

    if erosion_form_2 == "Sheet erosion in small parallel rills":
        erosion_rate = 1.7
        eroded_mass = round(erosion_rate * area_ha, 3)
        eroded_volume = round(eroded_mass / DENSITY_T_PER_M3, 3)
        return erosion_rate, eroded_mass, eroded_volume

    if erosion_form_2 in (
        "Sheet erosion in wheel tracks",
        "Erosion in wheel tracks",
    ):
        affected_tracks = safe_float(affected_wheel_tracks)
        if affected_tracks is None or affected_tracks < 1:
            return None, None, None

        erosion_rate = round(0.75 * affected_tracks, 3)
        raw_mass = 0.75 * affected_tracks * area_ha
        eroded_mass = 0.001 if raw_mass < 0.001 else round(raw_mass, 3)
        eroded_volume = round(eroded_mass / DENSITY_T_PER_M3, 3)
        return erosion_rate, eroded_mass, eroded_volume

    return None, None, None


def run_sheet_erosion(idctx, sysctx=None):
    warnings = []
    skipped = []

    raw_areas = load_layer(RAW_GPKG, RAW_SHEET_EROSION_AREAS)
    parcels = load_layer(PROC_GPKG, PROCESSED_PARCELS)
    sheet_erosion = load_layer(PROC_GPKG, PROCESSED_SHEET_EROSION)

    area_transform = QgsCoordinateTransform(raw_areas.crs(), parcels.crs(), QgsProject.instance())
    parcel_index, parcel_features = build_abp_index(parcels)
    existing_sheet_erosion_signatures = (
        build_existing_sheet_erosion_signatures(sheet_erosion)
    )

    raw_fields = field_names(raw_areas)
    if "Date" not in raw_fields:
        raise RuntimeError("RAW Sheet_Erosion layer is missing field: Date")
    if "Type" not in raw_fields:
        raise RuntimeError("RAW Sheet_Erosion layer is missing field: Type")

    new_sheet_erosion_features = []
    new_system_records = []

    for raw_feature in raw_areas.getFeatures():
        if not raw_feature.hasGeometry():
            continue

        date_str = date_only_str(raw_feature["Date"])
        if date_str is None:
            warnings.append(
                f"[WARN] Sheet erosion polygon without parseable date "
                f"(fid={raw_feature.id()}) -> skipped"
            )
            continue

        erosion_form_2 = normalize_sheet_erosion_form(raw_feature["Type"])
        if erosion_form_2 is None:
            warnings.append(
                f"[WARN] Sheet erosion polygon type not mapped "
                f"(fid={raw_feature.id()}, Type={raw_feature['Type']}) -> skipped"
            )
            continue

        geom = QgsGeometry(raw_feature.geometry())
        geom.transform(area_transform)
        try:
            geom = geom.makeValid()
        except Exception:
            pass

        if geom.isEmpty():
            warnings.append(
                f"[WARN] Sheet erosion polygon empty after transform "
                f"(fid={raw_feature.id()}) -> skipped"
            )
            continue

        use_entire_parcel = False
        if "Entire_Area" in raw_fields:
            use_entire_parcel = bool(_to_bool_int(raw_feature["Entire_Area"]))

        area_m2 = geom.area()
        abp_id, affected_wheel_tracks = abp_lookup_best_for_poly(parcel_index, parcel_features, geom)

        calculation_geometry = geom

        if use_entire_parcel:
            candidate_ids = parcel_index.intersects(geom.boundingBox())
            parcel_geom = None

            for fid in candidate_ids:
                parcel_feature = parcel_features.get(fid)
                if parcel_feature is None or not parcel_feature.hasGeometry():
                    continue
                try:
                    if (
                        safe_int(parcel_feature["ABP_ID"]) == int(abp_id)
                        and parcel_feature.geometry().intersects(geom)
                    ):
                        parcel_geom = parcel_feature.geometry()
                        break
                except Exception:
                    continue

            if parcel_geom is None:
                for fid in candidate_ids:
                    parcel_feature = parcel_features.get(fid)
                    if parcel_feature is None or not parcel_feature.hasGeometry():
                        continue
                    try:
                        if parcel_feature.geometry().intersects(geom):
                            parcel_geom = parcel_feature.geometry()
                            break
                    except Exception:
                        continue

            if parcel_geom is not None:
                try:
                    parcel_geom = parcel_geom.makeValid()
                except Exception:
                    pass

                if not parcel_geom.isEmpty():
                    calculation_geometry = parcel_geom
                    area_m2 = parcel_geom.area()
            else:
                warnings.append(
                    f"[WARN] Entire_Area=true but no parcel geometry found "
                    f"(fid={raw_feature.id()}, date={date_str})"
                )

        centroid_xy = geom_centroid_xy(calculation_geometry)
        if centroid_xy is not None:
            signature = (
                date_str,
                int(abp_id),
                round_xy(centroid_xy),
                round(float(area_m2), AREA_ROUND),
            )
            if signature in existing_sheet_erosion_signatures:
                skipped.append(
                    {
                        "date": date_str,
                        "module": "sheet_erosion",
                        "Type": erosion_form_2,
                        "ABP_ID": int(abp_id),
                        "raw_fid": raw_feature.id(),
                        "reason": "signature-exists",
                    }
                )
                continue
        else:
            warnings.append(
                f"[WARN] Sheet erosion centroid empty "
                f"(fid={raw_feature.id()}, date={date_str}) -> cannot check for duplicates safely"
            )

        erosion_parcel_id = idctx.allocate(
            abp_id,
            date_str,
            note=f"sheet_erosion date={date_str} raw_fid={raw_feature.id()}",
        )

        # A wheel-track count is required only for the wheel-track subtype.
        # For all other sheet-erosion types the value remains NULL.
        affected_track_count = None
        is_wheel_track_erosion = (
            erosion_form_2 == "Sheet erosion in wheel tracks"
        )

        if is_wheel_track_erosion:
            raw_wheel_track_field = resolve_field_name(
                raw_areas,
                "Affected_Wheel_Tracks",
            )

            if raw_wheel_track_field is None:
                warnings.append(
                    "[WARN] Sheet erosion in wheel tracks "
                    f"(fid={raw_feature.id()}, date={date_str}) cannot be "
                    "processed because RAW Sheet_Erosion has no "
                    "Affected_Wheel_Tracks field -> skipped"
                )
                continue

            affected_track_count = safe_int(
                raw_feature[raw_wheel_track_field]
            )

            if (
                affected_track_count is None
                or affected_track_count < 1
            ):
                warnings.append(
                    "[WARN] Sheet erosion in wheel tracks "
                    f"(fid={raw_feature.id()}, date={date_str}) has no "
                    "valid positive wheel-track count -> skipped"
                )
                continue

        erosion_rate, eroded_mass_t, eroded_volume_m3 = (
            calculate_sheet_erosion_metrics(
                area_m2,
                erosion_form_2,
                affected_track_count,
            )
        )

        erosion_system_id = None
        if sysctx is not None:
            raw_sedimentation = raw_feature["Sedimentation"] if "Sedimentation" in raw_fields else None
            raw_input = raw_feature["Input"] if "Input" in raw_fields else None
            raw_inflow = raw_feature["Inflow"] if "Inflow" in raw_fields else None
            raw_outflow = raw_feature["Outflow"] if "Outflow" in raw_fields else None
            raw_thalweg = raw_feature["Thalweg"] if "Thalweg" in raw_fields else None

            system_record = sysctx.ensure_sys_record(
                erosion_parcel_id=erosion_parcel_id,
                date_str=date_str,
                abp_id=abp_id,
                erosion_form_1="Sheet erosion",
                erosion_form_2=erosion_form_2,
                eroded_mass=eroded_mass_t,
                eroded_volume=eroded_volume_m3,
                erosion_depth_value=erosion_rate,
                eroded_area_value=round(float(area_m2), 3),
                raw_sedimentation=raw_sedimentation,
                raw_input=raw_input,
                raw_inflow=raw_inflow,
                raw_outflow=raw_outflow,
                raw_thalweg=raw_thalweg,
                system_geometry_4647=calculation_geometry,
            )
            if system_record is not None:
                system_feature, erosion_system_id = system_record
                new_system_records.append(system_feature)

        processed_feature = QgsFeature(sheet_erosion.fields())
        processed_feature.setGeometry(calculation_geometry)
        processed_feature["Erosion_Parcel_ID"] = erosion_parcel_id
        processed_feature["Date"] = date_str

        # These fields are optional in Sheet_Erosion_Processed. When present,
        # both receive the entered count only for wheel-track erosion.
        set_attr_if_exists(
            sheet_erosion,
            processed_feature,
            "Number_of_Affected_Wheel_Tracks",
            affected_track_count,
        )
        set_attr_if_exists(
            sheet_erosion,
            processed_feature,
            "Affected_Wheel_Tracks",
            affected_track_count,
        )

        processed_feature["ABP_ID"] = int(abp_id) if abp_id is not None else 9999
        processed_feature["Verified"] = None
        processed_feature["Erosion_Depth"] = erosion_rate
        processed_feature["Eroded_Mass"] = eroded_mass_t
        processed_feature["Eroded_Volume"] = eroded_volume_m3
        processed_feature["Eroded_Area"] = round(float(area_m2), 3)
        processed_feature["Erosion_System_ID"] = erosion_system_id

        new_sheet_erosion_features.append(processed_feature)

        if centroid_xy is not None:
            existing_sheet_erosion_signatures.add(signature)

    if new_sheet_erosion_features:
        ensure_edit(sheet_erosion)
        ok, _ = sheet_erosion.dataProvider().addFeatures(new_sheet_erosion_features)
        if not ok:
            raise RuntimeError("Append failed: Sheet_Erosion_Processed")
        commit(sheet_erosion)

    if new_system_records and sysctx is not None and sysctx.sys is not None:
        ensure_edit(sysctx.sys)
        ok_systems, _ = sysctx.sys.dataProvider().addFeatures(new_system_records)
        if not ok_systems:
            raise RuntimeError("Append failed: Erosion_Systems_Processed")
        commit(sysctx.sys)

    print("SHEET EROSION DONE ✅")
    print(f"Added Sheet_Erosion_Processed: {len(new_sheet_erosion_features)}")
    print_skips("SHEET_EROSION", skipped)

    if warnings:
        print("\n=== WARNINGS (SHEET EROSION) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")


# =============================================================================
# PART 4: LARGE DEPOSITION
# =============================================================================
def _geom_centroid_xy_num(geometry):
    try:
        centroid = geometry.centroid()
        if centroid and not centroid.isEmpty():
            point = centroid.asPoint()
            return float(point.x()), float(point.y())
    except Exception:
        pass
    return None, None


def build_existing_large_deposition_signatures(large_deposition_layer):
    """
    Existing signatures for Large_Deposition_Processed.

    The deposition ID may be stored under different historical names.
    """
    by_deposition_id = set()
    by_geometry = set()

    date_field = resolve_field_name(
        large_deposition_layer,
        "Date",
    )
    deposition_id_field = resolve_first_field_name(
        large_deposition_layer,
        [
            "Large_Deposition_ID",
            "Deposition_Class",
            "Deposition_Class_ID",
            "Deposition_ID",
        ],
    )

    for feature in large_deposition_layer.getFeatures():
        if not feature.hasGeometry():
            continue

        date_value = (
            feature[date_field]
            if date_field is not None
            else None
        )
        date_str = (
            str(date_value).strip()
            if date_value is not None
            else None
        )

        deposition_id = (
            safe_int(feature[deposition_id_field])
            if deposition_id_field is not None
            else None
        )

        geometry = feature.geometry()
        area = round(float(geometry.area()), 3)

        centroid_x, centroid_y = _geom_centroid_xy_num(geometry)
        centroid_x_rounded, centroid_y_rounded = (
            (round(centroid_x, 2), round(centroid_y, 2))
            if centroid_x is not None
            else (None, None)
        )

        if date_str is None:
            continue

        if deposition_id is not None:
            by_deposition_id.add(
                (date_str, int(deposition_id))
            )

        by_geometry.add(
            (
                date_str,
                area,
                centroid_x_rounded,
                centroid_y_rounded,
            )
        )

    return by_deposition_id, by_geometry


def run_large_deposition(idctx):
    warnings = []
    skipped = []

    raw_areas = load_layer(
        RAW_GPKG,
        RAW_LARGE_DEPOSITION_AREAS,
    )
    raw_points = load_layer(
        RAW_GPKG,
        RAW_LARGE_DEPOSITION_POINTS,
    )

    parcels = load_layer(
        PROC_GPKG,
        PROCESSED_PARCELS,
    )
    large_deposition = load_layer(
        PROC_GPKG,
        PROCESSED_LARGE_DEPOSITION,
    )

    areas_transform = QgsCoordinateTransform(
        raw_areas.crs(),
        parcels.crs(),
        QgsProject.instance(),
    )
    points_transform = QgsCoordinateTransform(
        raw_points.crs(),
        parcels.crs(),
        QgsProject.instance(),
    )

    parcel_index, parcel_features = build_abp_index(parcels)

    (
        existing_by_deposition_id,
        existing_by_geometry,
    ) = build_existing_large_deposition_signatures(
        large_deposition
    )

    raw_area_date_field = resolve_field_name(
        raw_areas,
        "Date",
    )
    if raw_area_date_field is None:
        raise RuntimeError(
            "RAW Large_Deposition_Area layer is missing field: Date"
        )

    raw_point_depth_field = resolve_field_name(
        raw_points,
        "Depth_cm",
    )
    if raw_point_depth_field is None:
        raise RuntimeError(
            "RAW Large_Deposition_Measurement_Points layer is "
            "missing field: Depth_cm"
        )

    # Current QML uses Large_Deposition_ID. Older files may use one of the
    # aliases below.
    area_deposition_id_field = resolve_first_field_name(
        raw_areas,
        [
            "Large_Deposition_ID",
            "Deposition_Class_ID",
            "Deposition_ID",
        ],
    )
    point_deposition_id_field = resolve_first_field_name(
        raw_points,
        [
            "Large_Deposition_ID",
            "Deposition_Class_ID",
            "Deposition_ID",
        ],
    )
    raw_point_date_field = resolve_field_name(
        raw_points,
        "Date",
    )

    if area_deposition_id_field is None:
        warnings.append(
            "[WARN] RAW Large_Deposition_Area has no recognized "
            "deposition ID field. Accepted names are "
            "Large_Deposition_ID, Deposition_Class_ID, and "
            "Deposition_ID. Geometry-only matching will be used."
        )

    if point_deposition_id_field is None:
        warnings.append(
            "[WARN] RAW Large_Deposition_Measurement_Points has no "
            "recognized deposition ID field. Geometry-only matching "
            "will be used."
        )

    memory_areas = QgsVectorLayer(
        "Polygon?crs=EPSG:4647",
        "tmp_large_deposition_area_4647",
        "memory",
    )
    provider = memory_areas.dataProvider()
    provider.addAttributes(
        [
            QgsField("src_fid", QVariant.Int),
            QgsField("Date", QVariant.String),
            QgsField("Large_Deposition_ID", QVariant.Int),
        ]
    )
    memory_areas.updateFields()

    area_geometry_by_mid = {}
    area_meta_by_mid = {}
    temp_features = []

    for raw_area_feature in raw_areas.getFeatures():
        if not raw_area_feature.hasGeometry():
            continue

        date_str = date_only_str(
            raw_area_feature[raw_area_date_field]
        )
        if date_str is None:
            warnings.append(
                "[WARN] Large deposition polygon without parseable "
                f"date (fid={raw_area_feature.id()}) -> skipped"
            )
            continue

        geometry = QgsGeometry(raw_area_feature.geometry())
        geometry.transform(areas_transform)

        try:
            geometry = geometry.makeValid()
        except Exception:
            pass

        if geometry.isEmpty():
            warnings.append(
                "[WARN] Large deposition polygon empty after transform "
                f"(fid={raw_area_feature.id()}) -> skipped"
            )
            continue

        deposition_id = (
            safe_int(
                raw_area_feature[area_deposition_id_field]
            )
            if area_deposition_id_field is not None
            else None
        )

        if (
            area_deposition_id_field is not None
            and deposition_id is None
        ):
            warnings.append(
                f"[WARN] Large deposition polygon fid="
                f"{raw_area_feature.id()} date={date_str} has no valid "
                f"{area_deposition_id_field} value."
            )

        area = round(float(geometry.area()), 3)
        centroid_x, centroid_y = _geom_centroid_xy_num(geometry)
        centroid_x_rounded, centroid_y_rounded = (
            (round(centroid_x, 2), round(centroid_y, 2))
            if centroid_x is not None
            else (None, None)
        )

        if (
            deposition_id is not None
            and (
                date_str,
                int(deposition_id),
            ) in existing_by_deposition_id
        ):
            skipped.append(
                {
                    "date": date_str,
                    "module": "large_deposition",
                    "raw_area_fid": raw_area_feature.id(),
                    "Large_Deposition_ID": int(deposition_id),
                    "reason": "already-by-deposition-id",
                }
            )
            continue

        geometry_signature = (
            date_str,
            area,
            centroid_x_rounded,
            centroid_y_rounded,
        )
        if geometry_signature in existing_by_geometry:
            skipped.append(
                {
                    "date": date_str,
                    "module": "large_deposition",
                    "raw_area_fid": raw_area_feature.id(),
                    "reason": "already-by-geometry",
                }
            )
            continue

        temp_feature = QgsFeature(memory_areas.fields())
        temp_feature.setGeometry(geometry)
        temp_feature["src_fid"] = raw_area_feature.id()
        temp_feature["Date"] = date_str
        temp_feature["Large_Deposition_ID"] = deposition_id
        temp_features.append(temp_feature)

    provider.addFeatures(temp_features)
    memory_areas.updateExtents()

    if memory_areas.featureCount() == 0:
        print("LARGE DEPOSITION DONE ✅ (nothing to add)")
        print_skips("LARGE_DEPOSITION", skipped)

        if warnings:
            print("\n=== WARNINGS (LARGE DEPOSITION) ===")
            for warning in warnings:
                print(warning)
            print("=== END WARNINGS ===\n")
        return

    memory_area_index = QgsSpatialIndex(
        memory_areas.getFeatures()
    )
    memory_areas_by_id = {
        feature.id(): feature
        for feature in memory_areas.getFeatures()
    }

    area_ids_by_date_and_deposition_id = defaultdict(list)
    area_ids_by_deposition_id = defaultdict(list)

    for memory_id, memory_feature in memory_areas_by_id.items():
        geometry = memory_feature.geometry()
        deposition_id = safe_int(
            memory_feature["Large_Deposition_ID"]
        )
        date_str = str(memory_feature["Date"])

        area_geometry_by_mid[memory_id] = geometry
        area_meta_by_mid[memory_id] = {
            "src_fid": int(memory_feature["src_fid"]),
            "Date": date_str,
            "Large_Deposition_ID": deposition_id,
        }

        if deposition_id is not None:
            area_ids_by_date_and_deposition_id[
                (date_str, int(deposition_id))
            ].append(memory_id)
            area_ids_by_deposition_id[
                int(deposition_id)
            ].append(memory_id)

    points_by_mid = defaultdict(list)

    for raw_point_feature in raw_points.getFeatures():
        if not raw_point_feature.hasGeometry():
            continue

        geometry = QgsGeometry(raw_point_feature.geometry())
        geometry.transform(points_transform)
        point_geom = QgsGeometry.fromPointXY(
            QgsPointXY(geometry.asPoint())
        )

        matched_area_id = None
        point_deposition_id = (
            safe_int(
                raw_point_feature[point_deposition_id_field]
            )
            if point_deposition_id_field is not None
            else None
        )
        point_date_str = (
            date_only_str(
                raw_point_feature[raw_point_date_field]
            )
            if raw_point_date_field is not None
            else None
        )

        # Preferred method: match the shared Large_Deposition_ID written by
        # the QML to both the polygon and its measurement points.
        id_candidates = []

        if point_deposition_id is not None:
            if point_date_str is not None:
                id_candidates = list(
                    area_ids_by_date_and_deposition_id.get(
                        (
                            point_date_str,
                            int(point_deposition_id),
                        ),
                        [],
                    )
                )

            if not id_candidates:
                id_candidates = list(
                    area_ids_by_deposition_id.get(
                        int(point_deposition_id),
                        [],
                    )
                )

        if len(id_candidates) == 1:
            matched_area_id = id_candidates[0]

        elif len(id_candidates) > 1:
            containing_id_candidates = [
                memory_id
                for memory_id in id_candidates
                if area_geometry_by_mid[memory_id].contains(
                    point_geom
                )
            ]

            candidate_pool = (
                containing_id_candidates
                if containing_id_candidates
                else id_candidates
            )
            matched_area_id = min(
                candidate_pool,
                key=lambda memory_id:
                    area_geometry_by_mid[memory_id].area(),
            )

            warnings.append(
                "[WARN] Large deposition point fid="
                f"{raw_point_feature.id()} matches multiple polygons "
                f"with Large_Deposition_ID={point_deposition_id}; "
                "the smallest candidate was chosen."
            )

        # Fallback method: spatial containment, useful for older data without
        # an ID column.
        if matched_area_id is None:
            candidate_ids = memory_area_index.intersects(
                point_geom.boundingBox()
            )
            containing_areas = [
                memory_id
                for memory_id in candidate_ids
                if area_geometry_by_mid[memory_id].contains(
                    point_geom
                )
            ]

            if len(containing_areas) == 1:
                matched_area_id = containing_areas[0]

            elif len(containing_areas) > 1:
                matched_area_id = min(
                    containing_areas,
                    key=lambda memory_id:
                        area_geometry_by_mid[memory_id].area(),
                )
                warnings.append(
                    "[WARN] Large deposition point fid="
                    f"{raw_point_feature.id()} intersects multiple "
                    "polygons -> smallest chosen"
                )

        if matched_area_id is None:
            id_text = (
                str(point_deposition_id)
                if point_deposition_id is not None
                else "NULL"
            )
            warnings.append(
                "[WARN] Large deposition point fid="
                f"{raw_point_feature.id()} could not be matched to a "
                f"polygon (Large_Deposition_ID={id_text}) -> ignored"
            )
            continue

        points_by_mid[matched_area_id].append(
            raw_point_feature
        )

    new_large_deposition_features = []

    for memory_id in memory_areas_by_id:
        meta = area_meta_by_mid[memory_id]
        date_str = meta["Date"]
        deposition_id = meta["Large_Deposition_ID"]
        geometry = area_geometry_by_mid[memory_id]
        area_m2 = float(geometry.area())

        point_features = points_by_mid.get(memory_id, [])
        if not point_features:
            id_text = (
                str(deposition_id)
                if deposition_id is not None
                else "NULL"
            )
            warnings.append(
                "[WARN] Large deposition polygon src_fid="
                f"{meta['src_fid']} date={date_str} "
                f"Large_Deposition_ID={id_text} has 0 matched "
                "measurement points -> skipped"
            )
            continue

        point_features_sorted = sorted(
            point_features,
            key=lambda feature: feature.id(),
        )

        depth_values = []
        for point_feature in point_features_sorted:
            depth = safe_float(
                point_feature[raw_point_depth_field]
            )
            if depth is not None:
                depth_values.append(depth)

        if not depth_values:
            warnings.append(
                "[WARN] Large deposition polygon src_fid="
                f"{meta['src_fid']} date={date_str} has points but "
                "no valid Depth_cm values -> skipped"
            )
            continue

        if len(point_features_sorted) != 5:
            warnings.append(
                "[WARN] Large deposition polygon src_fid="
                f"{meta['src_fid']} date={date_str} has "
                f"{len(point_features_sorted)} points (expected 5). "
                "Available points will be used; only the first 5 are "
                "stored in Measurement_Value_1..5."
            )

        measurement_values = [
            None,
            None,
            None,
            None,
            None,
        ]
        for index, point_feature in enumerate(
            point_features_sorted[:5]
        ):
            measurement_values[index] = safe_float(
                point_feature[raw_point_depth_field]
            )

        mean_deposition_depth_cm = (
            sum(depth_values) / float(len(depth_values))
        )
        deposition_volume_m3 = (
            area_m2 * (mean_deposition_depth_cm / 100.0)
        )
        deposition_mass_t = (
            deposition_volume_m3 * DENSITY_T_PER_M3
        )
        deposition_depth_value = (
            deposition_mass_t / (area_m2 / 10000.0)
            if area_m2 > 0
            else None
        )

        abp_id, _affected_tracks = abp_lookup_best_for_poly(
            parcel_index,
            parcel_features,
            geometry,
        )

        erosion_parcel_id = idctx.allocate(
            abp_id,
            date_str,
            note=(
                "large_deposition "
                f"date={date_str} "
                f"raw_area={meta['src_fid']}"
            ),
        )

        processed_feature = QgsFeature(
            large_deposition.fields()
        )
        processed_feature.setGeometry(geometry)
        processed_feature["Erosion_Parcel_ID"] = (
            erosion_parcel_id
        )
        processed_feature["Date"] = date_str
        processed_feature["Deposition_Depth_Cm"] = round(
            float(mean_deposition_depth_cm),
            3,
        )
        processed_feature["Deposition_Area"] = round(
            float(area_m2),
            3,
        )
        processed_feature["Deposition_Volume"] = round(
            float(deposition_volume_m3),
            3,
        )
        processed_feature["Deposition_Mass"] = round(
            float(deposition_mass_t),
            3,
        )
        processed_feature["Measurement_Value_1"] = (
            measurement_values[0]
        )
        processed_feature["Measurement_Value_2"] = (
            measurement_values[1]
        )
        processed_feature["Measurement_Value_3"] = (
            measurement_values[2]
        )
        processed_feature["Measurement_Value_4"] = (
            measurement_values[3]
        )
        processed_feature["Measurement_Value_5"] = (
            measurement_values[4]
        )

        # Preserve the ID when the processed schema has any accepted ID field.
        for output_id_name in (
            "Large_Deposition_ID",
            "Deposition_Class",
            "Deposition_Class_ID",
            "Deposition_ID",
        ):
            if set_attr_if_exists(
                large_deposition,
                processed_feature,
                output_id_name,
                deposition_id,
            ):
                break

        processed_feature["Deposition_Depth"] = (
            round(float(deposition_depth_value), 3)
            if deposition_depth_value is not None
            else None
        )
        processed_feature["Erosion_System_ID"] = None

        new_large_deposition_features.append(
            processed_feature
        )

    if new_large_deposition_features:
        ensure_edit(large_deposition)
        ok, _ = large_deposition.dataProvider().addFeatures(
            new_large_deposition_features
        )
        if not ok:
            raise RuntimeError(
                "Append failed: Large_Deposition_Processed"
            )
        commit(large_deposition)

    print("LARGE DEPOSITION DONE ✅")
    print(
        "Added Large_Deposition_Processed:",
        len(new_large_deposition_features),
    )
    print_skips("LARGE_DEPOSITION", skipped)

    if warnings:
        print("\n=== WARNINGS (LARGE DEPOSITION) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")


# =============================================================================
# PART 5: SMALL DEPOSITION
# =============================================================================
def parse_abp_id_from_erosion_parcel_id(erosion_parcel_id):
    """Extract ABP_ID from Erosion_Parcel_ID formatted as '<ABP>_<dd.MM.yyyy>_<sequence>'."""
    if erosion_parcel_id is None:
        return None

    value = str(erosion_parcel_id).strip()
    if not value:
        return None

    parts = value.split("_")
    if not parts:
        return None

    try:
        return int(parts[0])
    except Exception:
        return None


def build_existing_small_deposition_signatures(small_deposition_layer):
    """
    Build idempotency signatures for small deposition.

    Signature:
      (Date, ABP_ID, centroidXY_rounded, area_rounded, length_rounded)
    """
    signatures = set()
    field_name_list = field_names(small_deposition_layer)
    if "Date" not in field_name_list:
        return signatures

    has_erosion_parcel_id = "Erosion_Parcel_ID" in field_name_list

    for feature in small_deposition_layer.getFeatures():
        date_str = str(feature["Date"]).strip() if feature["Date"] is not None else None
        if not date_str:
            continue

        abp_id = None
        if has_erosion_parcel_id:
            abp_id = parse_abp_id_from_erosion_parcel_id(feature["Erosion_Parcel_ID"])
        if abp_id is None:
            continue

        if not feature.hasGeometry():
            continue

        geometry = feature.geometry()
        if geometry is None or geometry.isEmpty():
            continue

        centroid_xy = geom_centroid_xy(geometry)
        if centroid_xy is None:
            continue

        try:
            area = round(float(geometry.area()), AREA_ROUND)
        except Exception:
            area = None

        try:
            length = round(float(geometry.length()), LEN_ROUND)
        except Exception:
            length = None

        signature = (date_str, int(abp_id), round_xy(centroid_xy), area, length)
        signatures.add(signature)

    return signatures


def run_small_deposition(idctx):
    warnings = []
    skipped = []

    raw = load_layer(RAW_GPKG, RAW_SMALL_DEPOSITION)
    parcels = load_layer(PROC_GPKG, PROCESSED_PARCELS)
    small_deposition = load_layer(PROC_GPKG, PROCESSED_SMALL_DEPOSITION)

    transform = QgsCoordinateTransform(raw.crs(), parcels.crs(), QgsProject.instance())
    parcel_index, parcel_features = build_abp_index(parcels)

    existing_signatures = build_existing_small_deposition_signatures(small_deposition)

    next_object_id = max_int_field(small_deposition, "OBJECTID")
    next_small_deposition_id = max_int_field(small_deposition, "Small_Deposition_ID")

    raw_fields = field_names(raw)
    if "Date" not in raw_fields:
        raise RuntimeError("RAW Small_Deposition layer is missing field: Date")

    new_small_deposition_features = []

    for raw_feature in raw.getFeatures():
        if not raw_feature.hasGeometry():
            continue

        date_str = date_only_str(raw_feature["Date"])
        if date_str is None:
            warnings.append(
                f"[WARN] Small deposition feature without parseable date "
                f"(fid={raw_feature.id()}) -> skipped"
            )
            continue

        geometry = QgsGeometry(raw_feature.geometry())
        geometry.transform(transform)
        try:
            geometry = geometry.makeValid()
        except Exception:
            pass

        if geometry.isEmpty():
            warnings.append(
                f"[WARN] Small deposition geometry empty after transform "
                f"(fid={raw_feature.id()}, date={date_str}) -> skipped"
            )
            continue

        abp_id, _affected_tracks = abp_lookup_best_for_geom(parcel_index, parcel_features, geometry)

        centroid_xy = geom_centroid_xy(geometry)
        if centroid_xy is not None:
            area = round(float(geometry.area()), AREA_ROUND)
            length = round(float(geometry.length()), LEN_ROUND)
            signature = (date_str, int(abp_id), round_xy(centroid_xy), area, length)

            if signature in existing_signatures:
                skipped.append(
                    {
                        "date": date_str,
                        "module": "small_deposition",
                        "raw_fid": raw_feature.id(),
                        "ABP_ID": int(abp_id),
                        "reason": "signature-exists",
                    }
                )
                continue
        else:
            warnings.append(
                f"[WARN] Small deposition centroid empty "
                f"(fid={raw_feature.id()}, date={date_str}) -> cannot check for duplicates safely"
            )

        erosion_parcel_id = idctx.allocate(
            abp_id,
            date_str,
            note=f"small_deposition date={date_str} raw_fid={raw_feature.id()}",
        )

        next_object_id += 1
        next_small_deposition_id += 1

        processed_feature = QgsFeature(small_deposition.fields())
        processed_feature.setGeometry(geometry)
        processed_feature["OBJECTID"] = int(next_object_id)
        processed_feature["Erosion_Parcel_ID"] = erosion_parcel_id
        processed_feature["Date"] = date_str
        processed_feature["Small_Deposition_ID"] = int(next_small_deposition_id)
        processed_feature["Erosion_System_ID"] = None

        new_small_deposition_features.append(processed_feature)

        if centroid_xy is not None:
            existing_signatures.add(signature)

    if new_small_deposition_features:
        ensure_edit(small_deposition)
        ok, _ = small_deposition.dataProvider().addFeatures(new_small_deposition_features)
        if not ok:
            raise RuntimeError("Append failed: Small_Deposition_Processed")
        commit(small_deposition)

    print("SMALL DEPOSITION DONE ✅")
    print(f"Added Small_Deposition_Processed: {len(new_small_deposition_features)}")
    print_skips("SMALL_DEPOSITION", skipped)

    if warnings:
        print("\n=== WARNINGS (SMALL DEPOSITION) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")
        
# =============================================================================
# PART 6: COPY LINEAR
# =============================================================================
def run_copy_linear(idctx, sysctx=None):
    warnings = []
    skipped = []
    duplicates = []

    raw_points = load_layer(RAW_GPKG, RAW_COPY_LINEAR_POINTS)
    raw_linear_points = load_layer(RAW_GPKG, RAW_LINEAR_POINTS)
    measurement_lines = load_layer(PROC_GPKG, PROCESSED_MEASUREMENT_LINES)
    parcels = load_layer(PROC_GPKG, PROCESSED_PARCELS)
    copy_linear_lines = load_layer(PROC_GPKG, PROCESSED_COPY_LINEAR_LINES)
    copy_linear_points = load_layer(PROC_GPKG, PROCESSED_COPY_LINEAR_POINTS)

    system_layer = load_layer(PROC_GPKG, PROCESSED_EROSION_SYSTEMS)
    if sysctx is None:
        sysctx = SysContext(system_layer, parcels)

    new_system_records = []

    transform = QgsCoordinateTransform(raw_points.crs(), parcels.crs(), QgsProject.instance())

    distance = QgsDistanceArea()
    distance.setSourceCrs(parcels.crs(), QgsProject.instance().transformContext())

    parcel_index, parcel_features = build_abp_index(parcels)

    # Idempotency: same day + same Measurement_Line_ID + same centroid
    existing_line_signatures = set()
    for feature in copy_linear_lines.getFeatures():
        date_str = str(feature["Date"]).strip() if feature["Date"] is not None else None
        measurement_line_id = safe_int(feature["Measurement_Line_ID"])
        centroid_xy = geom_centroid_xy(feature.geometry()) if feature.hasGeometry() else None
        if date_str and measurement_line_id is not None and centroid_xy is not None:
            existing_line_signatures.add((date_str, int(measurement_line_id), round_xy(centroid_xy)))

    next_copy_linear_line_objectid = _next_int(copy_linear_lines, "OBJECTID", start=0)
    next_copy_linear_line_id = _next_int(copy_linear_lines, "Copy_Linear_Line_ID", start=0)
    next_copy_linear_point_objectid = _next_int(copy_linear_points, "OBJECTID", start=0)
    next_copy_linear_point_id = _next_int(copy_linear_points, "Copy_Linear_Point_ID", start=0)

    # Index processed measurement lines by (Date, Measurement_Line_ID)
    measurement_line_index = defaultdict(list)
    for feature in measurement_lines.getFeatures():
        if feature["Date"] and feature["Measurement_Line_ID"] is not None:
            measurement_line_index[
                (
                    str(feature["Date"]),
                    int(feature["Measurement_Line_ID"]),
                )
            ].append(feature)

    # Erosion_Form_2 index for Copy linear. The detailed type is read directly
    # from RAW linear measurement points and stored only in
    # Erosion_Systems_Processed.
    raw_linear_type_values = defaultdict(set)
    raw_linear_fields = field_names(raw_linear_points)

    if all(
        field_name in raw_linear_fields
        for field_name in ("Date", "Erosion_Line_ID", "Type")
    ):
        for feature in raw_linear_points.getFeatures():
            date_value = date_only_str(feature["Date"])
            line_id_value = safe_int(feature["Erosion_Line_ID"])
            type_value = _as_str(feature["Type"])

            if (
                date_value
                and line_id_value is not None
                and type_value
            ):
                raw_linear_type_values[
                    (date_value, int(line_id_value))
                ].add(type_value)

    raw_linear_type_index = {}
    for key, values in raw_linear_type_values.items():
        sorted_values = sorted(values)

        if len(sorted_values) > 1:
            warnings.append(
                "[WARN] Multiple RAW linear Type values found for "
                f"date={key[0]}, Measurement_Line_ID={key[1]}: "
                f"{sorted_values}. Using '{sorted_values[0]}'."
            )

        raw_linear_type_index[key] = sorted_values[0]

    # Group raw Copy_linear points by (Date, Erosion_Line_ID)
    groups = defaultdict(list)
    for feature in raw_points.getFeatures():
        date_str = date_only_str(feature["Date"])
        measurement_line_id = safe_int(feature["Erosion_Line_ID"])
        if date_str and measurement_line_id is not None:
            groups[(date_str, measurement_line_id)].append(feature)

    new_copy_linear_lines = []
    new_copy_linear_points = []

    def pick_best_reference_line(reference_lines, copy_linear_geometry):
        """If multiple reference lines exist for the same day and line id, pick the closest by centroid distance."""
        if not reference_lines:
            return None
        if len(reference_lines) == 1:
            return reference_lines[0]

        copy_linear_centroid = geom_centroid_xy(copy_linear_geometry)
        if copy_linear_centroid is None:
            return reference_lines[0]

        best_feature = None
        best_distance = None
        for ref_feature in reference_lines:
            if not ref_feature.hasGeometry():
                continue
            reference_centroid = geom_centroid_xy(ref_feature.geometry())
            if reference_centroid is None:
                continue
            centroid_distance = distance.measureLine(copy_linear_centroid, reference_centroid)
            if best_distance is None or centroid_distance < best_distance:
                best_distance = centroid_distance
                best_feature = ref_feature

        return best_feature or reference_lines[0]

    for (date_str, measurement_line_id), point_features in groups.items():
        if len(point_features) < 2:
            warnings.append(
                f"[WARN] Copy linear (date={date_str}, Measurement_Line_ID={measurement_line_id}) "
                f"has fewer than 2 points -> skipped"
            )
            continue

        # Only directly consecutive feature ids form a valid pair
        point_features_sorted = sorted(point_features, key=lambda feature: feature.id())
        i = 0

        while i < len(point_features_sorted) - 1:
            raw_point_0 = point_features_sorted[i]
            raw_point_1 = point_features_sorted[i + 1]

            fid0 = int(raw_point_0.id())
            fid1 = int(raw_point_1.id())

            if fid1 != fid0 + 1:
                warnings.append(
                    f"[WARN] Copy linear (date={date_str}, Measurement_Line_ID={measurement_line_id}) "
                    f"point fid={fid0} has no directly following fid -> skipped"
                )
                i += 1
                continue

            transformed_points = []
            for raw_point in [raw_point_0, raw_point_1]:
                if not raw_point.hasGeometry():
                    continue
                geom = QgsGeometry(raw_point.geometry())
                geom.transform(transform)
                transformed_points.append(QgsPointXY(geom.asPoint()))

            if len(transformed_points) < 2:
                warnings.append(
                    f"[WARN] Copy linear (date={date_str}, Measurement_Line_ID={measurement_line_id}, "
                    f"fids={fid0}/{fid1}) has fewer than 2 valid points after transform -> skipped"
                )
                i += 2
                continue

            point_0 = transformed_points[0]
            point_1 = transformed_points[1]
            copy_linear_geometry = QgsGeometry.fromPolylineXY([point_0, point_1])

            copy_linear_centroid = geom_centroid_xy(copy_linear_geometry)
            if copy_linear_centroid is None:
                warnings.append(
                    f"[WARN] Copy linear (date={date_str}, Measurement_Line_ID={measurement_line_id}, "
                    f"fids={fid0}/{fid1}) centroid empty -> skipped"
                )
                i += 2
                continue

            copy_linear_signature = (date_str, int(measurement_line_id), round_xy(copy_linear_centroid))
            if copy_linear_signature in existing_line_signatures:
                skipped.append(
                    {
                        "date": date_str,
                        "module": "copy_linear",
                        "Measurement_Line_ID": int(measurement_line_id),
                        "raw_fids": [fid0, fid1],
                        "reason": "same-day-same-line-same-centroid-exists",
                    }
                )
                i += 2
                continue

            copy_linear_length_m = distance.measureLine(point_0, point_1)

            reference_lines = measurement_line_index.get((date_str, measurement_line_id))
            if not reference_lines:
                warnings.append(
                    f"[WARN] No Measurement_Lines_Processed found for Copy linear "
                    f"(date={date_str}, Measurement_Line_ID={measurement_line_id}, fids={fid0}/{fid1})"
                )
                i += 2
                continue

            reference_line = pick_best_reference_line(reference_lines, copy_linear_geometry)
            if reference_line is None:
                warnings.append(
                    f"[WARN] Could not select reference Measurement_Lines_Processed for Copy linear "
                    f"(date={date_str}, Measurement_Line_ID={measurement_line_id}, fids={fid0}/{fid1})"
                )
                i += 2
                continue

            parcel_id, _ = abp_lookup_best_for_geom(
                parcel_index,
                parcel_features,
                QgsGeometry.fromPointXY(copy_linear_centroid),
            )

            cross_section = safe_float(reference_line["Cross_Section"]) or 0.0
            wheel_track_count = safe_int(reference_line["Number_of_Wheel_Tracks"]) or 1

            eroded_volume = (cross_section / 10000.0) * float(copy_linear_length_m) * float(wheel_track_count)
            eroded_mass = eroded_volume * DENSITY_T_PER_M3

            buffer_geometry = copy_linear_geometry.buffer(BUFFER_M, BUF_SEGMENTS, BUF_CAP, BUF_JOIN, BUF_MITER)
            try:
                buffer_geometry = buffer_geometry.makeValid()
            except Exception:
                pass

            parcel_union = abp_union_geom_for_buffer(parcel_index, parcel_features, buffer_geometry)
            intersected_area = 0.0
            if parcel_union:
                intersection = buffer_geometry.intersection(parcel_union)
                intersected_area = intersection.area() if intersection and not intersection.isEmpty() else 0.0

            erosion_depth_value = None
            if intersected_area > 0:
                erosion_depth_value = float(eroded_mass) / (float(intersected_area) / 10000.0)

            # Erosion_Form_2 is stored only in Erosion_Systems_Processed.
            # For Copy linear, obtain it directly from the linked RAW linear
            # measurement-point group.
            erosion_form_2 = raw_linear_type_index.get(
                (date_str, int(measurement_line_id))
            )

            if not erosion_form_2:
                warnings.append(
                    "[WARN] Copy linear could not determine Erosion_Form_2 for "
                    f"date={date_str}, "
                    f"Measurement_Line_ID={measurement_line_id}. "
                    "Erosion_Systems_Processed.Erosion_Form_2 will be NULL "
                    "for this Copy linear record."
                )

            collision_count_before = len(idctx.collisions)
            erosion_parcel_id = idctx.allocate(
                parcel_id,
                date_str,
                note=f"copy_linear raw_fids={fid0}/{fid1}",
            )

            eroded_volume_rounded = round(float(eroded_volume), 3)
            eroded_mass_rounded = round(float(eroded_mass), 3)
            eroded_area_rounded = round(float(intersected_area), 3)
            erosion_depth_rounded = round(float(erosion_depth_value), 3) if erosion_depth_value is not None else None

            erosion_system_id = None
            if sysctx is not None:
                system_record = sysctx.ensure_sys_record(
                    erosion_parcel_id=erosion_parcel_id,
                    date_str=date_str,
                    abp_id=parcel_id,
                    erosion_form_1="Linear erosion",
                    erosion_form_2=erosion_form_2,
                    eroded_mass=eroded_mass_rounded,
                    eroded_volume=eroded_volume_rounded,
                    erosion_depth_value=erosion_depth_rounded,
                    eroded_area_value=eroded_area_rounded,
                    system_geometry_4647=copy_linear_geometry,
                )
                if system_record is not None:
                    new_system_records.append(system_record[0])
                    erosion_system_id = system_record[1]

            if len(idctx.collisions) > collision_count_before:
                duplicates.append(idctx.collisions[-1])

            copy_linear_line_id = int(next_copy_linear_line_id)
            next_copy_linear_line_id += 1

            line_feature = QgsFeature(copy_linear_lines.fields())
            line_feature.setGeometry(copy_linear_geometry)

            if "OBJECTID" in field_names(copy_linear_lines):
                line_feature["OBJECTID"] = int(next_copy_linear_line_objectid)
                next_copy_linear_line_objectid += 1

            line_feature["Erosion_Parcel_ID"] = erosion_parcel_id
            line_feature["Date"] = date_str
            line_feature["Copy_Linear_Line_ID"] = copy_linear_line_id
            line_feature["Measurement_Line_ID"] = int(measurement_line_id)
            line_feature["Top_Width"] = reference_line["Top_Width"]
            line_feature["Bottom_Width"] = reference_line["Bottom_Width"]
            line_feature["Erosion_Depth"] = reference_line["Erosion_Depth"]
            line_feature["Erosion_Length"] = copy_linear_length_m
            line_feature["Cross_Section"] = reference_line["Cross_Section"]
            line_feature["Number_of_Wheel_Tracks"] = wheel_track_count
            line_feature["Cross_Section_Type"] = (
                reference_line["Cross_Section_Type"]
                if "Cross_Section_Type" in field_names(copy_linear_lines) else ""
            )
            line_feature["Eroded_Volume"] = eroded_volume_rounded
            line_feature["Eroded_Mass"] = eroded_mass_rounded
            line_feature["Legend_Type"] = reference_line["Legend_Type"]
            line_feature["ABP_ID"] = int(parcel_id)
            line_feature["Erosion_System_ID"] = erosion_system_id
            line_feature["Eroded_Area"] = eroded_area_rounded
            line_feature["Erosion_Depth"] = erosion_depth_rounded

            new_copy_linear_lines.append(line_feature)

            for point_xy in [point_0, point_1]:
                point_feature = QgsFeature(copy_linear_points.fields())
                point_feature.setGeometry(QgsGeometry.fromPointXY(point_xy))

                if "OBJECTID" in field_names(copy_linear_points):
                    point_feature["OBJECTID"] = int(next_copy_linear_point_objectid)
                    next_copy_linear_point_objectid += 1

                point_feature["Erosion_Parcel_ID"] = erosion_parcel_id
                point_feature["Date"] = date_str
                point_feature["Copy_Linear_Line_ID"] = copy_linear_line_id
                point_feature["Copy_Linear_Point_ID"] = int(next_copy_linear_point_id)
                next_copy_linear_point_id += 1
                point_feature["Erosion_System_ID"] = erosion_system_id
                new_copy_linear_points.append(point_feature)

            existing_line_signatures.add(copy_linear_signature)
            i += 2

        if i == len(point_features_sorted) - 1:
            warnings.append(
                f"[WARN] Copy linear (date={date_str}, Measurement_Line_ID={measurement_line_id}) "
                f"leftover unpaired point fid={point_features_sorted[i].id()} -> skipped"
            )

    if new_copy_linear_lines or new_copy_linear_points:
        ensure_edit(copy_linear_lines)
        ensure_edit(copy_linear_points)
        copy_linear_lines.dataProvider().addFeatures(new_copy_linear_lines)
        copy_linear_points.dataProvider().addFeatures(new_copy_linear_points)
        commit(copy_linear_lines)
        commit(copy_linear_points)

    if new_system_records and sysctx is not None and sysctx.sys is not None:
        ensure_edit(sysctx.sys)
        ok_systems, _ = sysctx.sys.dataProvider().addFeatures(new_system_records)
        if ok_systems:
            sysctx.sys.commitChanges()
        else:
            sysctx.sys.rollBack()
            warnings.append("[WARN] Could not add Erosion_Systems_Processed Copy linear records")

    print("COPY LINEAR DONE ✅")
    print(f"Added Copy_Linear_Lines_Processed: {len(new_copy_linear_lines)}")
    print(f"Added Copy_Linear_Points_Processed: {len(new_copy_linear_points)}")
    print_skips("COPY_LINEAR", skipped)

    if duplicates:
        print("\n=== DUPLICATE/COLLISION NOTES (auto-bumped suffix) ===")
        for duplicate in duplicates:
            print(duplicate)
        print("=== END DUPLICATE NOTES ===\n")

    if warnings:
        print("\n=== WARNINGS (COPY LINEAR) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")


# =============================================================================
# PART 7: RUNOFF
# =============================================================================
def run_runoff(idctx):
    warnings = []
    duplicates = []
    skipped = []

    raw = load_layer(RAW_GPKG, RAW_RUNOFF)
    parcels = load_layer(PROC_GPKG, PROCESSED_PARCELS)
    output = load_layer(PROC_GPKG, PROCESSED_RUNOFF)

    transform = QgsCoordinateTransform(
        raw.crs(),
        parcels.crs(),
        QgsProject.instance(),
    )
    parcel_index, parcel_features = build_abp_index(parcels)

    existing_signatures = build_existing_runoff_signatures(output)

    next_objectid = next_int_from_field(
        output,
        "OBJECTID",
        start=0,
    )
    next_runoff_id = next_int_from_field(
        output,
        "Runoff_ID",
        start=0,
    )

    raw_fields = field_names(raw)
    if "Date" not in raw_fields:
        raise RuntimeError(
            "RAW Runoff layer is missing field: Date"
        )
    if "Type" not in raw_fields:
        raise RuntimeError(
            "RAW Runoff layer is missing field: Type"
        )

    new_features = []

    for raw_feature in raw.getFeatures():
        if not raw_feature.hasGeometry():
            warnings.append(
                f"[WARN] Runoff without geometry "
                f"(fid={raw_feature.id()}) -> skipped"
            )
            continue

        date_str = date_only_str(raw_feature["Date"])
        if date_str is None:
            warnings.append(
                "[WARN] Runoff without parseable date "
                f"(fid={raw_feature.id()}) -> skipped"
            )
            continue

        runoff_type = normalize_runoff_type(
            raw_feature["Type"]
        )
        if not runoff_type:
            warnings.append(
                "[WARN] Runoff without type "
                f"(fid={raw_feature.id()}, date={date_str}) "
                "-> skipped"
            )
            continue

        geometry = QgsGeometry(raw_feature.geometry())
        geometry.transform(transform)

        if geometry.isEmpty():
            warnings.append(
                "[WARN] Runoff empty after transform "
                f"(fid={raw_feature.id()}, date={date_str}) "
                "-> skipped"
            )
            continue

        centroid_xy = geom_centroid_xy(geometry)
        if centroid_xy is None:
            warnings.append(
                "[WARN] Runoff centroid empty "
                f"(fid={raw_feature.id()}, date={date_str}) "
                "-> cannot check duplicates safely"
            )
            continue

        signature = (
            date_str,
            runoff_type,
            round_xy(centroid_xy),
        )
        if signature in existing_signatures:
            skipped.append(
                {
                    "date": date_str,
                    "module": "runoff",
                    "raw_fid": raw_feature.id(),
                    "Type": runoff_type,
                    "reason": "signature-exists",
                }
            )
            continue

        parcel_id, _ = abp_lookup_best_for_geom(
            parcel_index,
            parcel_features,
            QgsGeometry.fromPointXY(centroid_xy),
        )

        erosion_parcel_id = idctx.allocate(
            parcel_id,
            date_str,
            note=(
                f"runoff fid={raw_feature.id()} "
                f"date={date_str}"
            ),
        )

        output_feature = QgsFeature(output.fields())
        output_feature.setGeometry(geometry)

        if "OBJECTID" in field_names(output):
            output_feature["OBJECTID"] = int(next_objectid)
            next_objectid += 1

        output_feature["Erosion_Parcel_ID"] = (
            erosion_parcel_id
        )
        output_feature["Date"] = date_str
        output_feature["Runoff_ID"] = int(next_runoff_id)
        next_runoff_id += 1
        output_feature["Runoff_Type"] = runoff_type

        set_attr_if_exists(
            output,
            output_feature,
            "Erosion_System_ID",
            None,
        )

        new_features.append(output_feature)
        existing_signatures.add(signature)

    if new_features:
        ensure_edit(output)
        ok, _ = output.dataProvider().addFeatures(
            new_features
        )
        if not ok:
            raise RuntimeError(
                "Append failed: Runoff_Processed"
            )
        commit(output)

    print("RUNOFF DONE ✅")
    print(
        "Added Runoff_Processed:",
        len(new_features),
    )
    print_skips("RUNOFF", skipped)

    if duplicates:
        print(
            "\n=== DUPLICATE/COLLISION NOTES "
            "(auto-bumped suffix) ==="
        )
        for duplicate in duplicates:
            print(duplicate)
        print("=== END DUPLICATE NOTES ===\n")

    if warnings:
        print("\n=== WARNINGS (RUNOFF) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")


# =============================================================================
# PART 8: OVERLAND WATER FLOW
# =============================================================================
def run_overland_water_flow(idctx):
    warnings = []
    skipped = []

    raw = load_layer(
        RAW_GPKG,
        RAW_OVERLAND_WATER_FLOW,
    )
    parcels = load_layer(
        PROC_GPKG,
        PROCESSED_PARCELS,
    )
    output = load_layer(
        PROC_GPKG,
        PROCESSED_OVERLAND_WATER_FLOW,
    )

    transform = QgsCoordinateTransform(
        raw.crs(),
        parcels.crs(),
        QgsProject.instance(),
    )
    parcel_index, parcel_features = build_abp_index(parcels)

    # No custom ID field is required. Existing processed features are
    # identified by Date + Type + rounded point location.
    existing_signatures = (
        build_existing_overland_water_flow_signatures(output)
    )

    date_field = resolve_field_name(raw, "Date")
    type_field = resolve_field_name(raw, "Type")

    if date_field is None:
        raise RuntimeError(
            "RAW Overland_water_flow layer is missing field: Date"
        )

    if type_field is None:
        raise RuntimeError(
            "RAW Overland_water_flow layer is missing field: Type"
        )

    new_features = []

    for raw_feature in raw.getFeatures():
        raw_fid = raw_feature.id()

        if not raw_feature.hasGeometry():
            warnings.append(
                "[WARN] Overland water flow "
                f"raw_fid={raw_fid} has no geometry -> skipped"
            )
            continue

        date_str = date_only_str(
            raw_feature[date_field]
        )
        if date_str is None:
            warnings.append(
                "[WARN] Overland water flow without parseable date "
                f"(raw_fid={raw_fid}) -> skipped"
            )
            continue

        flow_type = normalize_overland_water_flow_type(
            raw_feature[type_field]
        )
        if not flow_type:
            warnings.append(
                "[WARN] Overland water flow without type "
                f"(raw_fid={raw_fid}, date={date_str}) -> skipped"
            )
            continue

        geometry = QgsGeometry(raw_feature.geometry())
        geometry.transform(transform)

        if geometry.isEmpty():
            warnings.append(
                "[WARN] Overland water flow empty after transform "
                f"(raw_fid={raw_fid}, date={date_str}) -> skipped"
            )
            continue

        centroid_xy = geom_centroid_xy(geometry)
        if centroid_xy is None:
            warnings.append(
                "[WARN] Overland water flow centroid empty "
                f"(raw_fid={raw_fid}, date={date_str}) -> skipped"
            )
            continue

        rounded_location = round_xy(centroid_xy)

        # The raw FID is useful for logs, but it is not copied into a custom
        # field because the processed GeoPackage creates its own FID.
        signature = (
            date_str,
            flow_type,
            rounded_location,
        )

        if signature in existing_signatures:
            skipped.append(
                {
                    "date": date_str,
                    "module": "overland_water_flow",
                    "raw_fid": raw_fid,
                    "Type": flow_type,
                    "location": rounded_location,
                    "reason": (
                        "same date, type, and rounded location "
                        "already exists"
                    ),
                }
            )
            continue

        parcel_id, _ = abp_lookup_best_for_geom(
            parcel_index,
            parcel_features,
            QgsGeometry.fromPointXY(centroid_xy),
        )

        erosion_parcel_id = idctx.allocate(
            parcel_id,
            date_str,
            note=(
                "overland_water_flow "
                f"raw_fid={raw_fid} "
                f"date={date_str} "
                f"location={rounded_location}"
            ),
        )

        output_feature = QgsFeature(output.fields())
        output_feature.setGeometry(geometry)
        output_feature["Erosion_Parcel_ID"] = (
            erosion_parcel_id
        )
        output_feature["Date"] = date_str
        output_feature["Type"] = flow_type

        set_attr_if_exists(
            output,
            output_feature,
            "Erosion_System_ID",
            None,
        )

        new_features.append(output_feature)
        existing_signatures.add(signature)

    if new_features:
        ensure_edit(output)
        ok, _ = output.dataProvider().addFeatures(
            new_features
        )
        if not ok:
            raise RuntimeError(
                "Append failed: Overland_water_flow_Processed"
            )
        commit(output)

    print("OVERLAND WATER FLOW DONE ✅")
    print(
        "Added Overland_water_flow_Processed:",
        len(new_features),
    )
    print_skips(
        "OVERLAND_WATER_FLOW",
        skipped,
    )

    if warnings:
        print("\n=== WARNINGS (OVERLAND WATER FLOW) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")


# =============================================================================
# PART 9: NOTES
#   RAW point + area -> PROCESSED Notes_Processed as points
#   Area is converted to centroid point
# =============================================================================
def run_notes():
    warnings = []
    added_note_points = 0
    added_note_areas = 0

    raw_note_areas = load_layer(RAW_GPKG, RAW_NOTE_AREAS)

    processed_notes = load_layer(PROC_GPKG, PROCESSED_NOTES)
    processed_note_areas = load_layer(PROC_GPKG, PROCESSED_NOTES_AREA)

    raw_fields = field_names(raw_note_areas)
    processed_note_fields = field_names(processed_notes)
    processed_note_area_fields = field_names(processed_note_areas)

    for required_field in ["Date", "Note"]:
        if required_field not in raw_fields:
            raise RuntimeError(f"RAW Note_Area layer is missing field: {required_field}")

    transform = QgsCoordinateTransform(raw_note_areas.crs(), processed_notes.crs(), QgsProject.instance())

    ensure_edit(processed_notes)
    ensure_edit(processed_note_areas)

    next_fid = max_int_field(processed_note_areas, "fid") + 1 if "fid" in processed_note_area_fields else None

    new_note_point_features = []
    new_note_area_features = []

    for raw_feature in raw_note_areas.getFeatures():
        if not raw_feature.hasGeometry():
            continue

        date_str = date_only_str(raw_feature["Date"])
        if not date_str:
            warnings.append(f"[WARN] Note area raw_fid={raw_feature.id()} without parseable date -> skipped")
            continue

        geom = QgsGeometry(raw_feature.geometry())
        geom.transform(transform)

        centroid = geom.centroid()
        if centroid is None or not centroid.isGeosValid():
            warnings.append(
                f"[WARN] Note area raw_fid={raw_feature.id()} centroid invalid "
                f"-> skipped Notes_Processed"
            )
        else:
            user_text = _as_str(raw_feature["Note"])
            note_text = _prefixed_centroid_note_text(user_text)

            point_feature = QgsFeature(processed_notes.fields())
            point_feature.setGeometry(centroid)

            if "Date" in processed_note_fields:
                point_feature["Date"] = date_str

            if "Text" in processed_note_fields:
                point_feature["Text"] = note_text
            elif "Note" in processed_note_fields:
                point_feature["Note"] = note_text
            else:
                warnings.append("[WARN] Notes_Processed has no obvious text field (Text/Note)")

            new_note_point_features.append(point_feature)
            added_note_points += 1

        area_feature = QgsFeature(processed_note_areas.fields())
        area_feature.setGeometry(geom)

        if next_fid is not None:
            area_feature["fid"] = int(next_fid)
            next_fid += 1

        if "Date" in processed_note_area_fields:
            area_feature["Date"] = date_str

        set_attr_if_exists(
            processed_note_areas,
            area_feature,
            "Crop",
            _as_str(raw_feature["Crop"]) if "Crop" in raw_fields else None,
        )
        set_attr_if_exists(
            processed_note_areas,
            area_feature,
            "Management",
            _as_str(raw_feature["Management"]) if "Management" in raw_fields else None,
        )
        set_attr_if_exists(
            processed_note_areas,
            area_feature,
            "Cover",
            safe_float(raw_feature["Cover"]) if "Cover" in raw_fields else None,
        )
        set_attr_if_exists(
            processed_note_areas,
            area_feature,
            "Growth_Stage",
            safe_float(raw_feature["Growth_Stage"]) if "Growth_Stage" in raw_fields else None,
        )
        set_attr_if_exists(
            processed_note_areas,
            area_feature,
            "Mulch_Cover",
            safe_float(raw_feature["Mulch_Cover"]) if "Mulch_Cover" in raw_fields else None,
        )
        set_attr_if_exists(
            processed_note_areas,
            area_feature,
            "Erosion",
            _to_bool_int(raw_feature["Erosion"]) if "Erosion" in raw_fields else None,
        )

        if "Photo1" in raw_fields:
            set_attr_if_exists(processed_note_areas, area_feature, "Photo1", _photo_clean_noext(raw_feature["Photo1"]))
        if "Photo2" in raw_fields:
            set_attr_if_exists(processed_note_areas, area_feature, "Photo2", _photo_clean_noext(raw_feature["Photo2"]))

        if "Note" in raw_fields:
            set_attr_if_exists(processed_note_areas, area_feature, "Note", _as_str(raw_feature["Note"]))

        new_note_area_features.append(area_feature)
        added_note_areas += 1

    if new_note_point_features:
        ok, _ = processed_notes.dataProvider().addFeatures(new_note_point_features)
        if not ok:
            raise RuntimeError("Append failed: Notes_Processed")

    if new_note_area_features:
        ok, _ = processed_note_areas.dataProvider().addFeatures(new_note_area_features)
        if not ok:
            raise RuntimeError("Append failed: Notes_Area_Processed")

    commit(processed_notes)
    commit(processed_note_areas)

    print("NOTES DONE ✅")
    print(f"Added Notes_Processed (centroid points): {added_note_points}")
    print(f"Added Notes_Area_Processed (polygons): {added_note_areas}")

    if warnings:
        print("\n=== WARNINGS (NOTES) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")


# =============================================================================
# PART 10: MANAGEMENT
#   RAW "Management" -> update Parcels attributes
# =============================================================================
def run_management():
    warnings = []
    skipped = []
    updated_existing_parcels = 0
    created_fallback_records = 0

    raw = load_layer(RAW_GPKG, RAW_MANAGEMENT)
    parcels = load_layer(PROC_GPKG, PROCESSED_PARCELS)

    # Resolve source and destination fields case-insensitively.
    raw_required_logical = [
        "Date",
        "Crop",
        "Management",
        "Cover",
        "Growth_Stage",
        "Mulch_Cover",
        "Erosion",
    ]
    raw_optional_logical = ["Photo1", "Photo2"]

    raw_field = {
        logical_name: resolve_field_name(raw, logical_name)
        for logical_name in raw_required_logical + raw_optional_logical
    }

    missing_raw_fields = [
        logical_name
        for logical_name in raw_required_logical
        if raw_field[logical_name] is None
    ]
    if missing_raw_fields:
        available = ", ".join(field_names(raw))
        raise RuntimeError(
            "RAW Management layer is missing required field(s): "
            + ", ".join(missing_raw_fields)
            + "\nAvailable fields: "
            + available
        )

    parcel_logical_names = [
        "ABP_ID",
        "Date",
        "Crop",
        "Management",
        "Cover",
        "Growth_Stage",
        "Mulch_Cover",
        "Erosion",
        "Photo1",
        "Photo2",
    ]
    parcel_field = {
        logical_name: resolve_field_name(parcels, logical_name)
        for logical_name in parcel_logical_names
    }

    if parcel_field["ABP_ID"] is None:
        raise RuntimeError(
            "Processed Parcels layer is missing required field: ABP_ID"
        )

    transform = QgsCoordinateTransform(
        raw.crs(),
        parcels.crs(),
        QgsProject.instance(),
    )

    # Only parcel features with geometry are used for spatial matching.
    # Attribute-only fallback records are intentionally ignored here.
    parcel_index = QgsSpatialIndex()
    parcel_features = {}
    for feature in parcels.getFeatures():
        if not feature.hasGeometry():
            continue
        parcel_index.addFeature(feature)
        parcel_features[feature.id()] = feature

    # Existing signatures make the Management module idempotent, including
    # fallback records with ABP_ID 9999 and no geometry.
    existing_signatures = set()

    if parcel_field["Date"] is not None:
        for feature in parcels.getFeatures():
            abp_id = safe_int(feature[parcel_field["ABP_ID"]])
            date_str = date_only_str(feature[parcel_field["Date"]])

            if abp_id is None or not date_str:
                continue

            crop_value = (
                _as_str(feature[parcel_field["Crop"]])
                if parcel_field["Crop"] is not None
                else ""
            )
            management_value = (
                _as_str(feature[parcel_field["Management"]])
                if parcel_field["Management"] is not None
                else ""
            )
            growth_stage_value = (
                _as_str(feature[parcel_field["Growth_Stage"]])
                if parcel_field["Growth_Stage"] is not None
                else ""
            )
            cover_value = (
                _as_str(feature[parcel_field["Cover"]])
                if parcel_field["Cover"] is not None
                else ""
            )
            mulch_cover_value = (
                _as_str(feature[parcel_field["Mulch_Cover"]])
                if parcel_field["Mulch_Cover"] is not None
                else ""
            )
            erosion_value = (
                _as_str(feature[parcel_field["Erosion"]])
                if parcel_field["Erosion"] is not None
                else ""
            )

            photo1 = (
                _photo_last10_noext(feature[parcel_field["Photo1"]])
                if parcel_field["Photo1"] is not None
                else None
            )
            photo2 = (
                _photo_last10_noext(feature[parcel_field["Photo2"]])
                if parcel_field["Photo2"] is not None
                else None
            )

            existing_signatures.add(
                (
                    int(abp_id),
                    date_str,
                    crop_value,
                    management_value,
                    growth_stage_value,
                    cover_value,
                    mulch_cover_value,
                    erosion_value,
                    photo1,
                    photo2,
                )
            )

    ensure_edit(parcels)

    def cast_parcel_value(logical_name, value):
        actual_field_name = parcel_field.get(logical_name)
        if actual_field_name is None:
            return None

        return _cast_for_abp_field(
            parcels,
            actual_field_name,
            value,
        )

    def set_new_feature_value(feature, logical_name, value):
        actual_field_name = parcel_field.get(logical_name)
        if actual_field_name is None:
            return

        feature[actual_field_name] = cast_parcel_value(
            logical_name,
            value,
        )

    for raw_number, raw_feature in enumerate(raw.getFeatures(), start=1):
        if not raw_feature.hasGeometry():
            warnings.append(
                f"[WARN] Management raw_fid={raw_feature.id()} "
                "has no geometry -> skipped"
            )
            continue

        date_value = raw_feature[raw_field["Date"]]
        date_str = date_only_str(date_value)

        if not date_str:
            warnings.append(
                f"[WARN] Management raw_fid={raw_feature.id()} "
                "without parseable date -> skipped"
            )
            continue

        crop_raw = _as_str(raw_feature[raw_field["Crop"]])
        management_raw = _as_str(raw_feature[raw_field["Management"]])
        growth_stage_raw = safe_float(
            raw_feature[raw_field["Growth_Stage"]]
        )
        cover_raw = safe_float(
            raw_feature[raw_field["Cover"]]
        )
        mulch_cover_raw = safe_float(
            raw_feature[raw_field["Mulch_Cover"]]
        )
        erosion_raw = _to_bool_int(
            raw_feature[raw_field["Erosion"]]
        )

        photo1 = _photo_last10_noext(
            raw_feature[raw_field["Photo1"]]
            if raw_field["Photo1"] is not None
            else None
        )
        photo2 = _photo_last10_noext(
            raw_feature[raw_field["Photo2"]]
            if raw_field["Photo2"] is not None
            else None
        )

        raw_photo1 = _as_str(
            raw_feature[raw_field["Photo1"]]
            if raw_field["Photo1"] is not None
            else None
        )
        raw_photo2 = _as_str(
            raw_feature[raw_field["Photo2"]]
            if raw_field["Photo2"] is not None
            else None
        )

        if raw_photo1 and len(raw_photo1) > 10:
            warnings.append(
                f"[WARN] Management raw_fid={raw_feature.id()} "
                f"Photo1 truncated -> '{photo1}'"
            )

        if raw_photo2 and len(raw_photo2) > 10:
            warnings.append(
                f"[WARN] Management raw_fid={raw_feature.id()} "
                f"Photo2 truncated -> '{photo2}'"
            )

        geom = QgsGeometry(raw_feature.geometry())
        geom.transform(transform)
        point_geom = QgsGeometry.fromPointXY(
            QgsPointXY(geom.asPoint())
        )

        parcel_match = _pick_abp_for_point(
            parcel_index,
            parcel_features,
            point_geom,
        )

        use_fallback_record = parcel_match is None

        if use_fallback_record:
            abp_id = int(MANAGEMENT_FALLBACK_ABP_ID)

            warnings.append(
                f"[WARN] Management raw_fid={raw_feature.id()} "
                "has no underlying parcel. "
                f"Using default ABP_ID={abp_id} and creating an "
                "attribute-only Parcels record with no geometry."
            )
        else:
            abp_id = safe_int(
                parcel_match[parcel_field["ABP_ID"]]
            )

            if abp_id is None:
                abp_id = int(MANAGEMENT_FALLBACK_ABP_ID)

                warnings.append(
                    f"[WARN] Management raw_fid={raw_feature.id()} "
                    f"matched parcel fid={parcel_match.id()} without a "
                    f"valid ABP_ID. Using default ABP_ID={abp_id}."
                )

        signature = (
            int(abp_id),
            date_str,
            crop_raw,
            management_raw,
            "" if growth_stage_raw is None else str(growth_stage_raw),
            "" if cover_raw is None else str(cover_raw),
            "" if mulch_cover_raw is None else str(mulch_cover_raw),
            "" if erosion_raw is None else str(erosion_raw),
            photo1,
            photo2,
        )

        if signature in existing_signatures:
            skipped.append(
                {
                    "date": date_str,
                    "raw_fid": raw_feature.id(),
                    "ABP_ID": int(abp_id),
                    "reason": "signature-exists",
                }
            )
            continue

        if use_fallback_record:
            # Parcels is a polygon layer, but GeoPackage layers can contain
            # features with NULL geometry. This preserves the Management data
            # without inventing a fake parcel polygon.
            fallback_feature = QgsFeature(parcels.fields())

            set_new_feature_value(
                fallback_feature,
                "ABP_ID",
                int(abp_id),
            )
            set_new_feature_value(
                fallback_feature,
                "Date",
                date_value,
            )
            set_new_feature_value(
                fallback_feature,
                "Crop",
                crop_raw,
            )
            set_new_feature_value(
                fallback_feature,
                "Management",
                management_raw,
            )
            set_new_feature_value(
                fallback_feature,
                "Growth_Stage",
                growth_stage_raw,
            )
            set_new_feature_value(
                fallback_feature,
                "Cover",
                cover_raw,
            )
            set_new_feature_value(
                fallback_feature,
                "Mulch_Cover",
                mulch_cover_raw,
            )
            set_new_feature_value(
                fallback_feature,
                "Erosion",
                erosion_raw,
            )

            if photo1:
                set_new_feature_value(
                    fallback_feature,
                    "Photo1",
                    str(photo1),
                )

            if photo2:
                set_new_feature_value(
                    fallback_feature,
                    "Photo2",
                    str(photo2),
                )

            if not parcels.addFeature(fallback_feature):
                parcels.rollBack()
                raise RuntimeError(
                    "Could not create a Management fallback record in "
                    f'Parcels with ABP_ID={abp_id}. The Parcels schema '
                    "may prohibit NULL geometry."
                )

            created_fallback_records += 1

        else:
            changes = {}

            def set_change(logical_name, value):
                actual_field_name = parcel_field.get(logical_name)
                if actual_field_name is None:
                    return

                field_index = parcels.fields().indexOf(
                    actual_field_name
                )
                changes[field_index] = cast_parcel_value(
                    logical_name,
                    value,
                )

            # Also writes ABP_ID=9999 when the matched polygon has no
            # valid ABP_ID.
            set_change("ABP_ID", int(abp_id))
            set_change("Crop", crop_raw)
            set_change("Growth_Stage", growth_stage_raw)
            set_change("Cover", cover_raw)
            set_change("Mulch_Cover", mulch_cover_raw)
            set_change("Erosion", erosion_raw)
            set_change("Date", date_value)

            if management_raw:
                set_change(
                    "Management",
                    str(management_raw),
                )

            if photo1:
                set_change(
                    "Photo1",
                    str(photo1),
                )

            if photo2:
                set_change(
                    "Photo2",
                    str(photo2),
                )

            ok = parcels.dataProvider().changeAttributeValues(
                {parcel_match.id(): changes}
            )

            if not ok:
                error_object = parcels.dataProvider().lastError()

                try:
                    error_message = error_object.message()
                except Exception:
                    error_message = str(error_object)

                print("\n[ERROR] Management update failed")
                print(
                    "Provider error:",
                    error_message if error_message else "(empty)",
                )
                print(
                    "Failed at raw feature #",
                    raw_number,
                    "raw_fid=",
                    raw_feature.id(),
                )
                print(
                    "Matched ABP_ID:",
                    abp_id,
                    "parcel_fid:",
                    parcel_match.id(),
                    "Date:",
                    date_str,
                    "Crop:",
                    crop_raw,
                )

                parcels.rollBack()

                raise RuntimeError(
                    "Management update failed — see the provider "
                    "error above."
                )

            updated_existing_parcels += 1

        existing_signatures.add(signature)

    commit(parcels)

    print("MANAGEMENT DONE ✅")
    print(
        "Updated matching Parcels:",
        updated_existing_parcels,
    )
    print(
        f"Created fallback Parcels records "
        f"(ABP_ID={MANAGEMENT_FALLBACK_ABP_ID}): "
        f"{created_fallback_records}"
    )

    print_skips("MANAGEMENT", skipped)

    if warnings:
        print("\n=== WARNINGS (MANAGEMENT) ===")
        for warning in warnings:
            print(warning)
        print("=== END WARNINGS ===\n")


# =============================================================================
# RUN ALL
# =============================================================================
def run():
    idctx = build_global_id_context()

    system_layer = try_load_layer(PROC_GPKG, PROCESSED_EROSION_SYSTEMS) if WRITE_SYS_RECORDS else None
    parcel_layer = try_load_layer(PROC_GPKG, PROCESSED_PARCELS) if WRITE_SYS_RECORDS else None
    sysctx = SysContext(system_layer, parcel_layer) if (WRITE_SYS_RECORDS and system_layer is not None) else None

    run_linear(idctx, sysctx)
    run_sheet_to_linear(idctx, sysctx)
    run_sheet_erosion(idctx, sysctx)
    run_large_deposition(idctx)
    run_small_deposition(idctx)
    run_copy_linear(idctx, sysctx)
    run_runoff(idctx)
    run_overland_water_flow(idctx)
    run_notes()
    run_management()

    if idctx.collisions:
        print("\n=== GLOBAL EROSION_PARCEL_ID COLLISION NOTES (auto-bumped suffix) ===")
        for collision in idctx.collisions[:200]:
            print(collision)
        if len(idctx.collisions) > 200:
            print(f"... ({len(idctx.collisions) - 200} more)")
        print("=== END GLOBAL COLLISION NOTES ===\n")


run()