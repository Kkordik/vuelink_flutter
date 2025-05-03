# Vuelink

## Overview

Vuelink is an offline communication application designed for airline operators to disseminate critical flight information during network connectivity outages. Utilizing Bluetooth Low Energy (BLE), it creates a decentralized mesh network for device-to-device transmission, ensuring passengers receive time-sensitive updates (boarding, gate changes, delays) even without Wi-Fi or cellular service in airport terminals.

The system employs a specific BLE advertisement protocol, optimized for extreme data minimization to maximize propagation efficiency within BLE's constraints.

## Problem Solved

Addresses the critical need for reliable flight information dissemination during network outages at airports, which can disrupt standard communication channels.

## Core Features

*   **BLE Advertisement Transmission & Scanning:** Devices broadcast and scan for Vuelink BLE packets, enabling discovery and data collection. Supports multi-part messages for larger content.
*   **Message Forwarding Protocol:** Received messages are forwarded once (by default) to extend reach across the mesh network, with mechanisms to prevent broadcast storms.
*   **Distributed Message Persistence:** Each device caches received messages locally to avoid redundant processing and track message history.
*   **Flight Information Rendering:** A dedicated UI displays prioritized, aviation-specific notifications clearly.
*   **Data Minimization Framework:** Uses binary encoding, lookup tables, and prioritization to transmit only essential data within BLE packet limits.
*   **Defined Message Types:** Supports various formats like general text, pre-loaded flight updates, and custom flight messages.

## Technical Architecture

*   **Platform:** Built with Flutter for cross-platform compatibility (Android & iOS).
*   **BLE Communication:**
    *   Manages advertisement.
    *   Handles assembly of multi-part messages. (Not finished)
    *   Implements forwarding logic.
*   **Storage:** Uses a local database (e.g., SQLite, Hive) for message caching and tracking.
*   **Processing:** Includes payload validation, duplicate detection, and priority classification.
*   **Data Optimization:** Employs binary encoding

## How It Works (Advertisement-Based Model) (In theory)

1.  **Origination:** An authorized device (e.g., airline personnel) creates a message (general or flight-specific).
2.  **Encoding & Transmission:** The message is encoded into one or more BLE advertisement packets adhering to strict size limits and Vuelink's format. Packets are broadcast periodically/once
3.  **Scanning & Discovery:** Nearby devices running Vuelink scan for these advertisement packets.
4.  **Assembly:** If a message is split into multiple parts, the receiving device collects all parts based on identifiers. (not finished)
5.  **Persistence & Deduplication:** The received message ID is checked against the local cache. If new (or marked for repeat), it's processed.
6.  **Forwarding:** The receiving device re-broadcasts the advertisement packet(s) once to propagate the message further into the mesh.
7.  **Rendering:** The assembled message is displayed to the user according to its type and priority.

