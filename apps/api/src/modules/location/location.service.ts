import { Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model } from 'mongoose';
import { GeographicCell, GeographicCellDocument } from '../../schemas/geographic-cell.schema';
import { Worker, WorkerDocument } from '../../schemas/worker.schema';

export interface AssignCellResult {
  cellId: string;
  wilayaCode: number;
  geoHash: string;
}

/**
 * LocationService handles geographic cell assignment.
 * Computes a deterministic cellId from lat/lng (2dp precision ≈ 1.1km grid),
 * creates the cell document if absent, and returns the result to callers so
 * they can persist it on the worker / user document.
 */
@Injectable()
export class LocationService {
  private readonly logger = new Logger(LocationService.name);

  private static readonly CELL_PRECISION = 2; // decimal places → ~1.1km grid
  private static readonly DEFAULT_RADIUS_KM = 5.0;

  constructor(
    @InjectModel(GeographicCell.name)
    private readonly cellModel: Model<GeographicCellDocument>,
    @InjectModel(Worker.name)
    private readonly workerModel: Model<WorkerDocument>,
  ) {}

  /**
   * Assign a worker to a geographic cell based on current GPS position.
   * Creates the cell document if it does not yet exist.
   */
  async assignWorkerToCell(
    workerId: string,
    latitude: number,
    longitude: number,
    wilayaCode: number,
  ): Promise<AssignCellResult> {
    try {
      const cellId  = this.buildCellId(latitude, longitude, wilayaCode);
      const geoHash = this.encodeGeoHash(latitude, longitude, 6);

      await this.ensureCellExists(cellId, latitude, longitude, wilayaCode);

      await this.workerModel
        .updateOne(
          { _id: workerId },
          {
            cellId,
            wilayaCode,
            geoHash,
            lastCellUpdate: new Date(),
          },
        )
        .exec();

      return { cellId, wilayaCode, geoHash };
    } catch (err) {
      this.logger.error(`LocationService.assignWorkerToCell(${workerId}) failed`, err);
      throw err;
    }
  }

  /**
   * Return workers in a given cell, optionally filtered by profession.
   */
  async getWorkersInCell(
    cellId: string,
    serviceType?: string,
    onlineOnly = false,
    limit = 50,
  ): Promise<WorkerDocument[]> {
    try {
      const query: Partial<Record<string, unknown>> = { cellId };
      if (serviceType) query['profession'] = serviceType;
      if (onlineOnly)  query['isOnline']   = true;
      return await this.workerModel.find(query).limit(limit).exec();
    } catch (err) {
      this.logger.error(`LocationService.getWorkersInCell(${cellId}) failed`, err);
      throw err;
    }
  }

  /**
   * Return adjacent cell IDs for a given center cell (ring of 8 neighbours).
   */
  getAdjacentCellIds(cellId: string): string[] {
    const parts = cellId.split('_');
    if (parts.length !== 3) return [];

    const [wilayaCode, latStr, lngStr] = parts;
    const lat   = parseFloat(latStr);
    const lng   = parseFloat(lngStr);
    const step  = Math.pow(10, -LocationService.CELL_PRECISION);
    const prec  = LocationService.CELL_PRECISION;

    const ids: string[] = [];
    for (let dLat = -1; dLat <= 1; dLat++) {
      for (let dLng = -1; dLng <= 1; dLng++) {
        if (dLat === 0 && dLng === 0) continue;
        const adjLat = +(lat + dLat * step).toFixed(prec);
        const adjLng = +(lng + dLng * step).toFixed(prec);
        ids.push(`${wilayaCode}_${adjLat.toFixed(prec)}_${adjLng.toFixed(prec)}`);
      }
    }
    return ids;
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  private buildCellId(lat: number, lng: number, wilayaCode: number): string {
    const p    = LocationService.CELL_PRECISION;
    const rLat = +lat.toFixed(p);
    const rLng = +lng.toFixed(p);
    return `${wilayaCode}_${rLat.toFixed(p)}_${rLng.toFixed(p)}`;
  }

  private async ensureCellExists(
    cellId: string,
    lat: number,
    lng: number,
    wilayaCode: number,
  ): Promise<void> {
    const exists = await this.cellModel.exists({ _id: cellId });
    if (!exists) {
      const adjacentCellIds = this.getAdjacentCellIds(cellId);
      await this.cellModel
        .findByIdAndUpdate(
          cellId,
          {
            wilayaCode,
            centerLat: +lat.toFixed(LocationService.CELL_PRECISION),
            centerLng: +lng.toFixed(LocationService.CELL_PRECISION),
            radius:    LocationService.DEFAULT_RADIUS_KM,
            adjacentCellIds,
          },
          { upsert: true },
        )
        .exec();
    }
  }

  /**
   * Minimal standard geohash encoder — precision 6 ≈ 1.2 × 0.6 km.
   */
  private encodeGeoHash(lat: number, lng: number, precision: number): string {
    const BASE32  = '0123456789bcdefghjkmnpqrstuvwxyz';
    let   hash    = '';
    let   isEven  = true;
    let   bit     = 0;
    let   ch      = 0;
    let   latMin  = -90.0, latMax = 90.0;
    let   lngMin  = -180.0, lngMax = 180.0;

    while (hash.length < precision) {
      let mid: number;
      if (isEven) {
        mid = (lngMin + lngMax) / 2;
        if (lng >= mid) { ch |= (1 << (4 - bit)); lngMin = mid; } else { lngMax = mid; }
      } else {
        mid = (latMin + latMax) / 2;
        if (lat >= mid) { ch |= (1 << (4 - bit)); latMin = mid; } else { latMax = mid; }
      }
      isEven = !isEven;
      if (bit < 4) { bit++; } else { hash += BASE32[ch]; bit = 0; ch = 0; }
    }
    return hash;
  }
}
