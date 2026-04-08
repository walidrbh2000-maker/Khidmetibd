import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { IsInt, IsNumber, Max, Min } from 'class-validator';
import { FirebaseAuthGuard } from '../../common/guards/firebase-auth.guard';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { AuthUser } from '../../common/guards/firebase-auth.guard';
import { LocationService, AssignCellResult } from './location.service';
import { WorkerDocument } from '../../schemas/worker.schema';

class AssignCellDto {
  @IsNumber() @Min(-90) @Max(90)   latitude: number;
  @IsNumber() @Min(-180) @Max(180) longitude: number;
  @IsInt() @Min(1) @Max(58)        wilayaCode: number;
}

@Controller('location')
@UseGuards(FirebaseAuthGuard)
export class LocationController {
  constructor(private readonly locationService: LocationService) {}

  /**
   * POST /location/workers/:id/cell
   * Assign a worker to their geographic cell based on GPS position.
   */
  @Post('workers/:id/cell')
  @HttpCode(HttpStatus.OK)
  async assignWorkerCell(
    @Param('id') id: string,
    @Body() dto: AssignCellDto,
    @CurrentUser() user: AuthUser,
  ): Promise<AssignCellResult> {
    // Workers may only assign themselves; admins could be added later.
    if (id !== user.uid) {
      throw new Error('Forbidden: you can only assign your own cell');
    }
    return this.locationService.assignWorkerToCell(
      id,
      dto.latitude,
      dto.longitude,
      dto.wilayaCode,
    );
  }

  /**
   * GET /location/cells/:cellId/workers
   * Workers in a specific geographic cell.
   */
  @Get('cells/:cellId/workers')
  async getWorkersInCell(
    @Param('cellId') cellId: string,
    @Query('serviceType') serviceType?: string,
    @Query('onlineOnly') onlineOnlyStr?: string,
    @Query('limit') limitStr?: string,
  ): Promise<WorkerDocument[]> {
    const onlineOnly = onlineOnlyStr === 'true';
    const limit = limitStr ? parseInt(limitStr, 10) : 50;
    return this.locationService.getWorkersInCell(cellId, serviceType, onlineOnly, limit);
  }

  /**
   * GET /location/cells/:cellId/adjacent
   * Returns the 8 adjacent cell IDs for grid navigation.
   */
  @Get('cells/:cellId/adjacent')
  getAdjacentCells(@Param('cellId') cellId: string): { adjacentCellIds: string[] } {
    return { adjacentCellIds: this.locationService.getAdjacentCellIds(cellId) };
  }
}
