from qgis.core import QgsVectorLayer
from datetime import datetime

# -----------------------------
# CONFIG
# -----------------------------
PROC_GPKG = r"C:\Users\barthe-n\QField\cloud\test_local\erosion_data_processed.gpkg"
CUTOFF_DATE_STR = "25.02.2026"   # delete EVERYTHING on or after this date

# Processed output layers that contain the Date field
DATE_FIELD = "Date"

PROCESSED_LAYERS = [
    "Measurement_Points_Processed",
    "Measurement_Lines_Processed",
    "Measurement_Points_SheetToLinear_Processed",
    "Measurement_Lines_SheetToLinear_Processed",
    "Sheet_To_Linear_Processed",
    "Sheet_Erosion_Processed",
    "Large_Deposition_Processed",
    "Small_Deposition_Processed",
    "Copy_Linear_Lines_Processed",
    "Copy_Linear_Points_Processed",
    "Runoff_Processed",
    "Overland_water_flow_Processed",
    "Notes_Processed",
    "Notes_Area_Processed",
    "Erosion_Systems_Processed",
]

# -----------------------------
# HELPERS
# -----------------------------
def load_layer(gpkg, name):
    uri = f"{gpkg}|layername={name}"
    vl = QgsVectorLayer(uri, name, "ogr")
    if not vl.isValid():
        print(f"[SKIP] Layer not found: {name}")
        return None
    return vl

def parse_date_value(value):
    """Return a Python datetime from common QGIS/string date values."""
    if value is None:
        return None

    # QDateTime/QDate values from QGIS
    try:
        py_value = value.toPyDateTime()
        if py_value is not None:
            return py_value
    except Exception:
        pass

    try:
        py_date = value.toPyDate()
        if py_date is not None:
            return datetime.combine(py_date, datetime.min.time())
    except Exception:
        pass

    text = str(value).strip()
    if not text:
        return None

    for date_format in (
        "%d.%m.%Y",
        "%d.%m.%Y %H:%M:%S",
        "%Y-%m-%d",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
    ):
        try:
            return datetime.strptime(text[:19], date_format)
        except Exception:
            continue

    return None

cutoff_dt = parse_date_value(CUTOFF_DATE_STR)
if cutoff_dt is None:
    raise RuntimeError("Invalid cutoff date format, must be dd.MM.yyyy")

# -----------------------------
# DELETE FEATURES
# -----------------------------
print("=== START CLEANUP ===")
print("Cutoff date:", CUTOFF_DATE_STR)

for lname in PROCESSED_LAYERS:
    layer = load_layer(PROC_GPKG, lname)
    if layer is None:
        continue

    if DATE_FIELD not in [f.name() for f in layer.fields()]:
        print(f"[SKIP] {lname}: no {DATE_FIELD} field")
        continue

    to_delete = []

    for f in layer.getFeatures():
        dt = parse_date_value(f[DATE_FIELD])
        if dt and dt >= cutoff_dt:
            to_delete.append(f.id())

    if not to_delete:
        print(f"[OK] {lname}: nothing to delete")
        continue

    layer.startEditing()
    layer.deleteFeatures(to_delete)
    layer.commitChanges()

    print(f"[DELETED] {lname}: {len(to_delete)} features")

print("=== CLEANUP DONE ✅ ===")
