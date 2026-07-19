# -*- coding: utf-8 -*-
# =============================================================================
# QGIS Python Console script — prepare the next EroMapper mapping campaign
#
# Current English schema only.
#
# What it does:
# 1. Creates timestamped backups of:
#      erosion_data.gpkg
#      erosion_data_processed.gpkg
#
# 2. Carries Management attributes from the processed parcel layer to the
#    raw parcel layer, matched by ABP_ID.
#
#    Exact layer names:
#      processed source: Parcels
#      raw destination:  Parcels
#
#    Only the current English field names are supported.
#
# 3. Deletes all collected field-mapping features from the listed RAW layers,
#    while keeping each layer's schema.
#
# Run in QGIS:
#   Plugins > Python Console > Show Editor > open this file > Run Script
# =============================================================================

from datetime import datetime
from pathlib import Path
import shutil

from qgis.core import QgsVectorLayer


# -----------------------------------------------------------------------------
# PATHS
# -----------------------------------------------------------------------------
RAW_GPKG = Path(
    r"C:\Users\barthe-n\QField\cloud\test_local\erosion_data.gpkg"
)
PROCESSED_GPKG = Path(
    r"C:\Users\barthe-n\QField\cloud\test_local"
    r"\erosion_data_processed.gpkg"
)

BACKUP_DIR_RAW = Path(
    r"C:\Users\barthe-n\QField\cloud\backup_mapped"
)
BACKUP_DIR_PROCESSED = Path(
    r"C:\Users\barthe-n\QField\cloud\backup_processed"
)


# -----------------------------------------------------------------------------
# SWITCHES
# -----------------------------------------------------------------------------
DO_BACKUP_RAW = True
DO_BACKUP_PROCESSED = True
DO_COPY_MANAGEMENT_TO_RAW_PARCELS = True
DO_RESET_RAW_LAYERS = True


# -----------------------------------------------------------------------------
# PARCEL LAYER NAMES
# -----------------------------------------------------------------------------
PROCESSED_PARCEL_LAYER = "Parcels"
RAW_PARCEL_LAYER = "Parcels"
PARCEL_KEY_FIELD = "ABP_ID"


# -----------------------------------------------------------------------------
# MANAGEMENT FIELDS
# -----------------------------------------------------------------------------
PARCEL_FIELDS_TO_COPY = [
    "Growth_Stage",
    "Crop",
    "Cover",
    "Mulch_Cover",
    "Erosion",
    "Date",
    "Management",
]


# -----------------------------------------------------------------------------
# RAW DATA-CAPTURE LAYERS TO EMPTY
# -----------------------------------------------------------------------------
RAW_LAYERS_TO_RESET = [
    "Linear_Erosion_Measurement_Points",
    "Sheet_To_Linear_Linear_Measurement_Points",
    "Sheet_To_Linear_Area",
    "Sheet_Erosion",
    "Large_Deposition_Measurement_Points",
    "Large_Deposition_Area",
    "Small_Deposition",
    "Copy_linear",
    "Runoff",
    "Overland_water_flow",
    "Note_Point",
    "Note_Area",
    "Management",
    "Photos",
]


# =============================================================================
# GENERAL HELPERS
# =============================================================================
def timestamp():
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def backup_file(source_path, backup_directory, output_stem=None):
    source_path = Path(source_path)
    backup_directory = Path(backup_directory)

    if not source_path.exists():
        raise FileNotFoundError(f"File not found:\n{source_path}")

    backup_directory.mkdir(parents=True, exist_ok=True)

    stem = output_stem or source_path.stem
    destination = backup_directory / (
        f"{stem}_{timestamp()}{source_path.suffix}"
    )
    shutil.copy2(source_path, destination)
    return destination


def layer_uri(gpkg_path, layer_name):
    return f"{gpkg_path}|layername={layer_name}"


def try_load_layer(gpkg_path, layer_name):
    layer = QgsVectorLayer(
        layer_uri(gpkg_path, layer_name),
        layer_name,
        "ogr",
    )
    return layer if layer.isValid() else None


def load_layer(gpkg_path, layer_name):
    layer = try_load_layer(gpkg_path, layer_name)

    if layer is None:
        raise RuntimeError(
            f'Layer could not be loaded: "{layer_name}" from '
            f"{gpkg_path}"
        )

    return layer


def field_names(layer):
    return [field.name() for field in layer.fields()]


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


def ensure_edit(layer):
    if layer.isEditable():
        return

    if not layer.startEditing():
        raise RuntimeError(
            f'Could not start editing layer "{layer.name()}".'
        )


def commit(layer):
    if not layer.isEditable():
        return

    if not layer.commitChanges():
        errors = layer.commitErrors()
        raise RuntimeError(
            f'Commit failed for layer "{layer.name()}":\n'
            + "\n".join(errors)
        )


def delete_all_features(layer):
    """Delete all records while keeping the layer schema."""
    provider = layer.dataProvider()

    # Fast provider truncate where supported.
    if hasattr(provider, "truncate"):
        try:
            if provider.truncate():
                return
        except Exception:
            pass

    feature_ids = [
        feature.id()
        for feature in layer.getFeatures()
    ]

    if not feature_ids:
        return

    ensure_edit(layer)

    if not layer.deleteFeatures(feature_ids):
        layer.rollBack()
        raise RuntimeError(
            f'Could not delete features from "{layer.name()}".'
        )

    commit(layer)


# =============================================================================
# BACKUPS
# =============================================================================
def create_backups():
    if DO_BACKUP_RAW:
        raw_backup = backup_file(
            RAW_GPKG,
            BACKUP_DIR_RAW,
            output_stem="erosion_data",
        )
        print(f"[OK] RAW backup:\n  {raw_backup}")

    if DO_BACKUP_PROCESSED:
        processed_backup = backup_file(
            PROCESSED_GPKG,
            BACKUP_DIR_PROCESSED,
            output_stem="erosion_data_processed",
        )
        print(
            f"[OK] Processed backup:\n  {processed_backup}"
        )


# =============================================================================
# MANAGEMENT CARRYOVER
# =============================================================================
def resolve_carryover_fields(source_layer, destination_layer):
    """
    Return current English carryover fields that exist in both parcel layers.

    ABP_ID is the only mandatory field. Missing optional fields are reported
    and skipped, matching the behavior of the original preparation script.
    """
    source_fields = set(field_names(source_layer))
    destination_fields = set(field_names(destination_layer))

    if PARCEL_KEY_FIELD not in source_fields:
        raise RuntimeError(
            f'"{source_layer.name()}" in the processed GeoPackage is '
            f'missing required field: {PARCEL_KEY_FIELD}'
        )

    if PARCEL_KEY_FIELD not in destination_fields:
        raise RuntimeError(
            f'"{destination_layer.name()}" in the raw GeoPackage is '
            f'missing required field: {PARCEL_KEY_FIELD}'
        )

    fields_to_copy = [
        field_name
        for field_name in PARCEL_FIELDS_TO_COPY
        if (
            field_name in source_fields
            and field_name in destination_fields
        )
    ]

    missing_source = [
        field_name
        for field_name in PARCEL_FIELDS_TO_COPY
        if field_name not in source_fields
    ]
    missing_destination = [
        field_name
        for field_name in PARCEL_FIELDS_TO_COPY
        if field_name not in destination_fields
    ]

    if missing_source:
        print(
            "[SKIP] Processed Parcels is missing optional field(s): "
            + ", ".join(missing_source)
        )

    if missing_destination:
        print(
            "[SKIP] Raw Parcels is missing optional field(s): "
            + ", ".join(missing_destination)
        )

    return fields_to_copy


def copy_management_to_raw_parcels():
    source_layer = load_layer(
        PROCESSED_GPKG,
        PROCESSED_PARCEL_LAYER,
    )
    destination_layer = load_layer(
        RAW_GPKG,
        RAW_PARCEL_LAYER,
    )

    fields_to_copy = resolve_carryover_fields(
        source_layer,
        destination_layer,
    )

    if not fields_to_copy:
        print(
            "[WARNING] No optional English parcel fields exist in both "
            "GeoPackages. Management carryover was skipped."
        )
        return

    source_by_abp_id = {}

    for source_feature in source_layer.getFeatures():
        abp_id = safe_int(
            source_feature[PARCEL_KEY_FIELD]
        )
        if abp_id is None:
            continue

        source_by_abp_id[int(abp_id)] = {
            field_name: source_feature[field_name]
            for field_name in fields_to_copy
        }

    ensure_edit(destination_layer)

    updated_features = 0
    unchanged_features = 0
    source_not_found = 0

    for destination_feature in destination_layer.getFeatures():
        abp_id = safe_int(
            destination_feature[PARCEL_KEY_FIELD]
        )
        if abp_id is None:
            continue

        source_values = source_by_abp_id.get(int(abp_id))
        if source_values is None:
            source_not_found += 1
            continue

        changed = False

        for field_name, value in source_values.items():
            if destination_feature[field_name] != value:
                destination_feature[field_name] = value
                changed = True

        if not changed:
            unchanged_features += 1
            continue

        if not destination_layer.updateFeature(
            destination_feature
        ):
            destination_layer.rollBack()
            raise RuntimeError(
                "Failed updating raw Parcels feature "
                f"(ABP_ID={abp_id})."
            )

        updated_features += 1

    commit(destination_layer)

    print("MANAGEMENT CARRYOVER DONE")
    print(
        f'  Source: "{PROCESSED_PARCEL_LAYER}" '
        f'({PROCESSED_GPKG.name})'
    )
    print(
        f'  Destination: "{RAW_PARCEL_LAYER}" '
        f'({RAW_GPKG.name})'
    )
    print(f"  Updated parcels: {updated_features}")
    print(f"  Already unchanged: {unchanged_features}")
    print(
        "  Raw ABP_ID values without a processed source: "
        f"{source_not_found}"
    )
    print(
        "  Copied fields: "
        + ", ".join(fields_to_copy)
    )


# =============================================================================
# RESET RAW DATA-CAPTURE LAYERS
# =============================================================================
def reset_raw_layers():
    reset_count = 0
    already_empty_count = 0
    missing_count = 0

    for layer_name in RAW_LAYERS_TO_RESET:
        layer = try_load_layer(RAW_GPKG, layer_name)

        if layer is None:
            print(
                f'[SKIP] RAW layer not found: "{layer_name}"'
            )
            missing_count += 1
            continue

        feature_count = layer.featureCount()

        if feature_count == 0:
            print(f'[EMPTY] "{layer_name}"')
            already_empty_count += 1
            continue

        delete_all_features(layer)
        print(
            f'[RESET] "{layer_name}": '
            f"deleted {feature_count} feature(s)"
        )
        reset_count += 1

    print("RAW RESET DONE")
    print(f"  Layers reset: {reset_count}")
    print(f"  Already empty: {already_empty_count}")
    print(f"  Missing/skipped: {missing_count}")


# =============================================================================
# RUN
# =============================================================================
def run():
    if not RAW_GPKG.exists():
        raise FileNotFoundError(
            f"RAW GeoPackage not found:\n{RAW_GPKG}"
        )

    if not PROCESSED_GPKG.exists():
        raise FileNotFoundError(
            "Processed GeoPackage not found:\n"
            f"{PROCESSED_GPKG}"
        )

    # Back up before any changes to either GeoPackage.
    create_backups()

    if DO_COPY_MANAGEMENT_TO_RAW_PARCELS:
        copy_management_to_raw_parcels()

    if DO_RESET_RAW_LAYERS:
        reset_raw_layers()

    print("\nALL DONE ✅")


run()
