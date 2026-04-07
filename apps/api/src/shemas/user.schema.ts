import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document } from 'mongoose';

export type UserDocument = User & Document;

@Schema({ collection: 'users', timestamps: false, versionKey: false })
export class User {
  @Prop({ required: true, index: true })
  _id: string;

  @Prop({ required: true })
  name: string;

  @Prop({ required: true, lowercase: true, trim: true })
  email: string;

  @Prop({ default: '' })
  phoneNumber: string;

  @Prop({ type: Number, default: null })
  latitude: number | null;

  @Prop({ type: Number, default: null })
  longitude: number | null;

  @Prop({ required: true, type: Date })
  lastUpdated: Date;

  @Prop({ type: String, default: null })
  profileImageUrl: string | null;

  @Prop({ type: String, default: null, index: true })
  cellId: string | null;

  @Prop({ type: Number, default: null, index: true })
  wilayaCode: number | null;

  @Prop({ type: String, default: null })
  geoHash: string | null;

  @Prop({ type: String, default: null })
  fcmToken: string | null;
}

export const UserSchema = SchemaFactory.createForClass(User);

UserSchema.index({ wilayaCode: 1 });
UserSchema.index({ geoHash: 1 });
UserSchema.index({ email: 1 }, { unique: true });
