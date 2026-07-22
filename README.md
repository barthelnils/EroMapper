# EroMapper

EroMapper is a QField plugin for the guided field mapping of water-induced soil erosion. It provides dedicated, task-specific forms for recording management information, linear and sheet erosion, sheet-to-linear erosion, sediment deposition, runoff points, overland flow, notes, and photographs.

By guiding users through standardized, task-specific input steps, creating the required geometries, automatically selecting the appropriate layer, and storing entries directly in the corresponding GeoPackage layer, the plugin simplifies field data collection and reduces the risk of incomplete, inconsistent, or incorrectly assigned records. Users therefore do not need to switch manually between layers or use QField’s standard feature editor, as the complete mapping workflow is handled through the plugin interface. The accompanying QGIS post-processing scripts subsequently transform the collected raw observations into standardized, analysis-ready output layers.

## Requirements
- QGIS
- QField on the field device
- A QFieldCloud account for cloud synchronization, or a method for transferring the complete project folder locally
- The EroMapper template GeoPackages from the `Template_project` folder

Optional:
- The QFieldSync QGIS plugin and a QFieldCloud account for cloud synchronization, or a method for transferring the complete project folder locally

## Installation

1. Create a new QGIS project and install **QFieldSync**.
2. Create a QFieldCloud project and select a local project folder.
3. Copy `erosion_data.gpkg` (can be found in `Template_project`) into that folder and add the required layers to QGIS. Keep the provided layer and field names unchanged.
4. Upload the project with QFieldSync, or transfer the complete project folder locally to the device.
5. Open the project in QField and disable the standard editing mode, since EroMapper uses its own digitizing tools.
6. Download, install, and enable the EroMapper plugin from the GitHub Release (see https://docs.qfield.org/how-to/advanced-how-tos/plugins/).

## Usage

After the project and plugin are loaded, EroMapper adds a toolbar with guided mapping tools.

### Main tools

- **Management** records crop and management information for an agricultural parcel.
- **Sheet erosion** records an affected polygon and its erosion characteristics.
- **Linear erosion** records a rill or gully as a sequence of measurement points. Mark the final point to complete the line.
- **Copy linear erosion** records a new start-to-end segment linked to an existing linear erosion through its `Erosion_Line_ID`. The post-processing script reuses the measurements of the original line.
- **Sheet-to-linear erosion** combines an affected area with corresponding linear measurement points.
- **Deposition** records small point deposits or large deposits with an area and measurement points.
- **Runoff** records a single runoff or sediment-transfer point, for example where material enters a ditch, road, stream, or adjacent parcel.
- **Overland water flow** records water-flow observations such as inlets and outlets.
- **Notes** records point or area observations with free text.
- **Photos** records georeferenced photographs.
- **Glossary** provides short explanations of the mapping categories.

### General workflow

1. Select the required EroMapper tool.
2. Use the current GPS position or the map-centre crosshair, depending on the tool.
3. Follow the displayed steps and enter the requested measurements and attributes.
4. Save the observation.
5. Repeat for the remaining erosion features.
6. Synchronize the project back to QFieldCloud or transfer the modified project folder back to the desktop.


### Post-processing

After fieldwork:

1. Download or synchronize the latest raw data to the desktop.
3. Open QGIS and run `Post_processing_scripts/processing.py` from the QGIS Python Console.
4. Review all warnings and skipped-feature messages.
5. Inspect the generated processed layers before analysis or publication.


### Preparing the next mapping campaign

Run `Post_processing_scripts/prep_next_mapping.py` only after the current campaign has been synchronized, processed, checked, and backed up.

The script can:

- create timestamped backups;
- carry selected parcel-management attributes to the next campaign;
- clear the raw observation layers while preserving their schemas.

Never run preparation, cleanup, reset, or migration scripts without a verified backup.


