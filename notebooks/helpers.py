"""
helpers.py — utility functions for species_stats.ipynb

All pure functions are defined here to keep the notebook clean.
Imported at the top of the notebook with `from helpers import *`.
"""
import os
import sqlite3
import numpy as np
import pandas as pd
import plotly.graph_objects as go
from datetime import datetime, timedelta
from dateutil import tz
from suntime import Sun


# ── Database ──────────────────────────────────────────────────────────────────

def get_connection(path):
    """Open SQLite DB in read-only mode."""
    uri = f"file:{path}?mode=ro"
    return sqlite3.connect(uri, uri=True, check_same_thread=False)


def load_data(conn):
    """
    Load all detections and normalise Com_Name to the most recent label per
    scientific name (matches the web app's language-change behaviour).
    Returns a DataFrame indexed by DateTime.
    """
    df = pd.read_sql(
        "SELECT Date, Time, Sci_Name, Com_Name, Confidence, File_Name FROM detections",
        con=conn,
    )
    if df.empty:
        raise ValueError("No detections found in database.")
    latest = df.groupby("Sci_Name").tail(1)[["Sci_Name", "Com_Name"]].set_index("Sci_Name")
    df = df.rename(columns={"Com_Name": "Directory"})
    df["DateTime"] = pd.to_datetime(df["Date"] + " " + df["Time"])
    df = df.merge(latest, how="left", on="Sci_Name").set_index("DateTime")
    return df


# ── Data helpers ───────────────────────────────────────────────────────────────

RESAMPLE_MAP = {"Raw": None, "15 minutes": "15min", "Hourly": "1h", "Daily": "1D"}


def apply_date_filter(df, start, end):
    filt = (df.index >= pd.Timestamp(start)) & (
        df.index < pd.Timestamp(end) + timedelta(days=1)
    )
    return df[filt]


def apply_resample(df, resample_key):
    rule = RESAMPLE_MAP[resample_key]
    if rule is None:
        return df["Com_Name"]
    return df.resample(rule)["Com_Name"].aggregate("unique").explode()


# ── Time helpers ───────────────────────────────────────────────────────────────

def hms_to_dec(t):
    return t.hour + t.minute / 60 + t.second / 3600


def hms_to_str(t):
    return f"{t.hour:02d}:{t.minute:02d}"


def sunrise_sunset_scatter(date_range, latitude, longitude):
    """
    Return (x_dates, y_hours, hover_text) for a combined sunrise+sunset
    line trace (two segments joined by a None break).
    """
    sun = Sun(latitude, longitude)
    local_tz = tz.tzlocal()
    rise_y, set_y, rise_txt, set_txt, labels = [], [], [], [], []

    for d in date_range:
        dt = datetime.combine(d, datetime.min.time())
        sr = sun.get_sunrise_time(dt, local_tz)
        ss = sun.get_sunset_time(dt, local_tz)
        rise_y.append(sr.hour + sr.minute / 60)
        set_y.append(ss.hour + ss.minute / 60)
        rise_txt.append(f'{sr.strftime("%H:%M")} Sunrise')
        set_txt.append(f'{ss.strftime("%H:%M")} Sunset')
        labels.append(d.strftime("%d-%m-%Y"))

    x = labels + [None] + labels
    y = rise_y + [None] + set_y
    text = rise_txt + [None] + set_txt
    return x, y, text


# ── Chart helpers ──────────────────────────────────────────────────────────────

THETA24 = np.linspace(0.0, 360, 24, endpoint=False).tolist()

POLAR_LAYOUT = dict(
    radialaxis=dict(showticklabels=False),
    angularaxis=dict(
        rotation=-90,
        direction="clockwise",
        tickmode="array",
        tickvals=[
            0, 15, 30, 45, 60, 75, 90, 105, 120, 135, 150, 165,
            180, 195, 210, 225, 240, 255, 270, 285, 300, 315, 330, 345,
        ],
        ticktext=[
            "12am", "1am", "2am", "3am", "4am", "5am", "6am", "7am",
            "8am", "9am", "10am", "11am", "12pm", "1pm", "2pm", "3pm",
            "4pm", "5pm", "6pm", "7pm", "8pm", "9pm", "10pm", "11pm",
        ],
    ),
)


def polar_trace(hourly_row):
    d = pd.Series(np.zeros(24), index=range(24))
    d = (d + hourly_row).fillna(0)
    return go.Barpolar(r=d.tolist(), theta=THETA24, marker_color="seagreen", showlegend=False)


# ── Recording path ─────────────────────────────────────────────────────────────

def recording_path(row, recordings_dir):
    """Return (wav_path, png_path) for a detections row."""
    species_dir = row["Directory"].replace(" ", "_").replace("'", "")
    base = os.path.join(recordings_dir, "By_Date", row["Date"], species_dir, row["File_Name"])
    return base, base + ".png"
