import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document } from 'mongoose';
import { ServiceStatus, ServicePriority } from '../common/enums';

export type ServiceRequestDocument = ServiceRequest & Document;

@Schema({ collection: 'service_requests', timestamps: false, versionKey: false })
export class ServiceRequest {
  @Prop({ required: true, index: true })
  _id: string;

  @Prop({ required: true, index: true })
  userId: string;

  @Prop({ required: true })
  userName: string;

  @Prop({ required: true })
  userPhone: string;

  @Prop({ required: true, index: true })
  serviceType: string;

  @Prop({ required: true })
  title: string;

  @Prop({ required: true })
  description: string;

  @Prop({ required: true, type: Date })
  scheduledDate: Date;

  @Prop({ required: true, min: 0, max: 23 })
  scheduledHour: number;

  @Prop({ required: true, min: 0, max: 59 })
  scheduledMinute: number;

  @Prop({ required: true, enum: ServicePriority, default: ServicePriority.Normal })
  priority: ServicePriority;

  @Prop({ required: true, enum: ServiceStatus, default: ServiceStatus.Open, index: true })
  status: ServiceStatus;

  @Prop({ required: true })
  userLatitude: number;

  @Prop({ required: true })
  userLongitude: number;

  @Prop({ required: true })
  userAddress: string;

  @Prop({ type: [String], default: [] })
  mediaUrls: string[];

  @Prop({ default: 0, min: 0 })
  bidCount: number;

  @Prop({ type: Date, default: null })
  biddingDeadlineAt: Date | null;

  @Prop({ type: String, default: null })
  selectedBidId: string | null;

  @Prop({ type: Number, default: null })
  budgetMin: number | null;

  @Prop({ type: Number, default: null })
  budgetMax: number | null;

  @Prop({ type: String, default: null, index: true })
  workerId: string | null;

  @Prop({ type: String, default: null })
  workerName: string | null;

  @Prop({ type: Number, default: null })
  agreedPrice: number | null;

  @Prop({ required: true, type: Date, index: true })
  createdAt: Date;

  @Prop({ type: Date, default: null })
  bidSelectedAt: Date | null;

  @Prop({ type: Date, default: null })
  acceptedAt: Date | null;

  @Prop({ type: Date, default: null })
  completedAt: Date | null;

  @Prop({ type: String, default: null })
  workerNotes: string | null;

  @Prop({ type: Number, default: null })
  finalPrice: number | null;

  @Prop({ type: Number, default: null })
  estimatedPrice: number | null;

  @Prop({ type: Number, default: null })
  estimatedDuration: number | null;

  @Prop({ type: Number, default: null, min: 1, max: 5 })
  clientRating: number | null;

  @Prop({ type: String, default: null })
  reviewComment: string | null;

  @Prop({ type: String, default: null, index: true })
  cellId: string | null;

  @Prop({ type: Number, default: null, index: true })
  wilayaCode: number | null;

  @Prop({ type: String, default: null })
  geoHash: string | null;

  @Prop({ type: Date, default: null })
  lastCellUpdate: Date | null;
}

export const ServiceRequestSchema = SchemaFactory.createForClass(ServiceRequest);

ServiceRequestSchema.index({ userId: 1, createdAt: -1 });
ServiceRequestSchema.index({ workerId: 1, createdAt: -1 });
ServiceRequestSchema.index({ wilayaCode: 1, serviceType: 1, status: 1 });
ServiceRequestSchema.index({ status: 1, wilayaCode: 1, createdAt: -1 });
ServiceRequestSchema.index({ wilayaCode: 1, status: 1, workerId: 1 });
