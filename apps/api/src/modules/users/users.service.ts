import {
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model } from 'mongoose';
import { User, UserDocument } from '../../schemas/user.schema';
import { CreateUserDto } from '../../dto/create-user.dto';
import { UpdateUserDto } from '../../dto/update-user.dto';

@Injectable()
export class UsersService {
  private readonly logger = new Logger(UsersService.name);

  constructor(
    @InjectModel(User.name) private readonly userModel: Model<UserDocument>,
  ) {}

  async upsert(dto: CreateUserDto): Promise<UserDocument> {
    try {
      const doc = await this.userModel
        .findByIdAndUpdate(
          dto.id,
          {
            name: dto.name,
            email: dto.email,
            phoneNumber: dto.phoneNumber ?? '',
            latitude: dto.latitude ?? null,
            longitude: dto.longitude ?? null,
            profileImageUrl: dto.profileImageUrl ?? null,
            fcmToken: dto.fcmToken ?? null,
            lastUpdated: new Date(),
          },
          { upsert: true, new: true, runValidators: true },
        )
        .exec();
      if (!doc) throw new NotFoundException(`User ${dto.id} not found after upsert`);
      return doc;
    } catch (err) {
      this.logger.error('UsersService.upsert failed', err);
      throw err;
    }
  }

  async findById(id: string): Promise<UserDocument> {
    try {
      const doc = await this.userModel.findById(id).exec();
      if (!doc) throw new NotFoundException(`User ${id} not found`);
      return doc;
    } catch (err) {
      this.logger.error(`UsersService.findById(${id}) failed`, err);
      throw err;
    }
  }

  async update(id: string, dto: UpdateUserDto): Promise<UserDocument> {
    try {
      const patch: Partial<Record<string, unknown>> = { lastUpdated: new Date() };
      if (dto.name !== undefined)       patch['name']       = dto.name;
      if (dto.phoneNumber !== undefined) patch['phoneNumber'] = dto.phoneNumber;
      if (dto.profileImageUrl !== undefined) patch['profileImageUrl'] = dto.profileImageUrl;
      if (dto.cellId !== undefined)     patch['cellId']     = dto.cellId;
      if (dto.wilayaCode !== undefined) patch['wilayaCode'] = dto.wilayaCode;
      if (dto.geoHash !== undefined)    patch['geoHash']    = dto.geoHash;

      const doc = await this.userModel
        .findByIdAndUpdate(id, patch, { new: true, runValidators: true })
        .exec();
      if (!doc) throw new NotFoundException(`User ${id} not found`);
      return doc;
    } catch (err) {
      this.logger.error(`UsersService.update(${id}) failed`, err);
      throw err;
    }
  }

  async updateLocation(
    id: string,
    latitude: number,
    longitude: number,
    cellId?: string,
    wilayaCode?: number,
    geoHash?: string,
  ): Promise<void> {
    try {
      const patch: Partial<Record<string, unknown>> = {
        latitude,
        longitude,
        lastUpdated: new Date(),
      };
      if (cellId !== undefined)     patch['cellId']     = cellId;
      if (wilayaCode !== undefined) patch['wilayaCode'] = wilayaCode;
      if (geoHash !== undefined)    patch['geoHash']    = geoHash;

      const result = await this.userModel.updateOne({ _id: id }, patch).exec();
      if (result.matchedCount === 0) throw new NotFoundException(`User ${id} not found`);
    } catch (err) {
      this.logger.error(`UsersService.updateLocation(${id}) failed`, err);
      throw err;
    }
  }

  async updateFcmToken(id: string, fcmToken: string): Promise<void> {
    try {
      const result = await this.userModel
        .updateOne({ _id: id }, { fcmToken, lastUpdated: new Date() })
        .exec();
      if (result.matchedCount === 0) throw new NotFoundException(`User ${id} not found`);
    } catch (err) {
      this.logger.error(`UsersService.updateFcmToken(${id}) failed`, err);
      throw err;
    }
  }

  async clearFcmToken(id: string): Promise<void> {
    try {
      await this.userModel
        .updateOne({ _id: id }, { fcmToken: null, lastUpdated: new Date() })
        .exec();
    } catch (err) {
      this.logger.error(`UsersService.clearFcmToken(${id}) failed`, err);
      throw err;
    }
  }
}
