import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document } from 'mongoose';

export type WorkerDocument = Worker & Document;

@Schema({ collection: 'workers', timestamps: false, versionKey: false })
export class Worker {
  @Prop({ required: true, index: true })
  _id: string;

  @Prop({ required: true })
  name: string;

  @Prop({ required: true, lowercase: true, trim: true })
  email: string;

  @Prop({ default: '' })
  phoneNumber: string;

  @Prop({ required: true, index: true })
  profession: string;

  @Prop({ required: true, default: false, index: true })
  isOnline: boolean;

  @Prop({ type: Number, default: null })
  latitude: number | null;

  @Prop({ type: Number, default: null })
  longitude: number | null;

  @Prop({ required: true, type: Date })
  lastUpdated: Date;

  @Prop({ type: String, default: null, index: true })
  cellId: string | null;

  @Prop({ type: Number, default: null, index: true })
  wilayaCode: number | null;

  @Prop({ type: String, default: null })
  geoHash: string | null;

  @Prop({ type: Date, default: null })
  lastCellUpdate: Date | null;

  @Prop({ type: String, default: null })
  profileImageUrl: string | null;

  @Prop({ default: 0.0, min: 0, max: 5 })
  averageRating: number;

  @Prop({ default: 0, min: 0 })
  ratingCount: number;

  @Prop({ default: 0, min: 0 })
  ratingSum: number;

  @Prop({ default: 0, min: 0 })
  jobsCompleted: number;

  @Prop({ default: 0.7, min: 0, max: 1 })
  responseRate: number;

  @Prop({ type: Date, default: null })
  lastActiveAt: Date | null;

  @Prop({ type: String, default: null })
  fcmToken: string | null;
}

export const WorkerSchema = SchemaFactory.createForClass(Worker);

WorkerSchema.index({ isOnline: 1, wilayaCode: 1 });
WorkerSchema.index({ isOnline: 1, profession: 1 });
WorkerSchema.index({ wilayaCode: 1, profession: 1 });
WorkerSchema.index({ geoHash: 1 });
WorkerSchema.index({ cellId: 1, profession: 1, isOnline: 1 });
WorkerSchema.index({ email: 1 }, { unique: true });
